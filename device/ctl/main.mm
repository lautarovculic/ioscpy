// ioscpyctl: small on-device helper for status, diagnostics, and the privileged
// maintenance actions the Settings pane and the host driver rely on.

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import <errno.h>

#import "Protocol.h"
#import "Detect.h"
#import "Paths.h"

extern char **environ;

static NSString *const kLanConfigPath = @"/var/mobile/Library/Preferences/com.ioscpy.lan.plist";
static NSString *const kTrustPath = @"/var/mobile/Library/Preferences/com.ioscpy.trust.plist";

static int connectLoopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// Handshake with the daemon and return the parsed HELLO_ACK, or nil.
static NSDictionary *fetchHandshake(uint16_t port) {
    int fd = connectLoopback(port);
    if (fd < 0) {
        return nil;
    }
    NSDictionary *hello = @{
        @"role": @"ctl",
        @"host_version": @"0.3.0-dream.9",
        @"protocol_version": @(IOSPY_PROTOCOL_VERSION),
        @"nonce": @"00",
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    NSDictionary *result = nil;
    if (IOSPYWriteFrame(fd, IOSPYMsgHello, IOSPY_CHANNEL_CONTROL, 0, body)) {
        IOSPYFrameHeader hdr;
        NSData *payload = nil;
        if (IOSPYReadFrame(fd, &hdr, &payload) && hdr.type == IOSPYMsgHelloAck) {
            result = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        }
    }
    close(fd);
    return result;
}

static int sendPrivilegedMessage(IOSPYMessageType type, NSData *commandPayload) {
    int fd = connectLoopback(IOSPY_DEFAULT_PORT);
    if (fd < 0) return 1;
    NSDictionary *hello = @{
        @"role": @"ctl",
        @"host_version": @"0.3.0-dream.9",
        @"protocol_version": @(IOSPY_PROTOCOL_VERSION),
        @"nonce": @"00",
    };
    NSData *helloData = [NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    int result = 1;
    if (IOSPYWriteFrame(fd, IOSPYMsgHello, IOSPY_CHANNEL_CONTROL, 0, helloData)) {
        IOSPYFrameHeader header;
        NSData *ackData = nil;
        if (IOSPYReadFrame(fd, &header, &ackData) && header.type == IOSPYMsgHelloAck) {
            NSDictionary *ack = [NSJSONSerialization JSONObjectWithData:ackData options:0 error:nil];
            NSString *token = [ack[@"session_token"] isKindOfClass:[NSString class]]
                ? ack[@"session_token"] : nil;
            NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
            if (tokenData.length > 0 &&
                IOSPYWriteFrame(fd, IOSPYMsgAuthenticate, IOSPY_CHANNEL_CONTROL, 1, tokenData) &&
                IOSPYWriteFrame(fd, type, IOSPY_CHANNEL_CONTROL, 2,
                                commandPayload ?: [NSData data])) {
                result = 0;
            }
        }
    }
    close(fd);
    return result;
}

static void printDeviceInfo(void) {
    printf("model       %s\n", IOSPYDeviceModel().UTF8String);
    printf("ios         %s\n", IOSPYSystemVersion().UTF8String);
    printf("jailbreak   %s\n", IOSPYLayoutName(IOSPYDetectLayout()).UTF8String);
    NSString *prefix = IOSPYJBPrefix();
    printf("prefix      %s\n", prefix.length ? prefix.UTF8String : "/");
    printf("injection   %s\n", IOSPYInjectionFramework().UTF8String);
}

static int cmdStatus(void) {
    printDeviceInfo();
    NSDictionary *ack = fetchHandshake(IOSPY_DEFAULT_PORT);
    if (ack) {
        printf("daemon      running (version %s, protocol %s)\n",
               [ack[@"daemon_version"] description].UTF8String,
               [ack[@"protocol_version"] description].UTF8String);
    } else {
        printf("daemon      not reachable on 127.0.0.1:%u\n", IOSPY_DEFAULT_PORT);
    }
    BOOL hook = [[NSFileManager defaultManager]
        fileExistsAtPath:IOSPYPath(@"/Library/MobileSubstrate/DynamicLibraries/ioscpyhook.dylib")];
    printf("tweak       %s\n", hook ? "installed" : "missing");
    return ack ? 0 : 1;
}

static int cmdCapabilities(void) {
    NSDictionary *ack = fetchHandshake(IOSPY_DEFAULT_PORT);
    if (!ack) {
        fprintf(stderr, "daemon not reachable\n");
        return 1;
    }
    NSData *pretty = [NSJSONSerialization dataWithJSONObject:ack[@"capabilities"]
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:nil];
    fwrite(pretty.bytes, 1, pretty.length, stdout);
    printf("\n");
    return 0;
}

// Run a shell command (system() isn't available on iOS). PATH points at the
// prefix bins so tools like launchctl, tar, and chmod resolve under any layout.
static int runShell(NSString *command) {
    NSString *prefix = IOSPYJBPrefix();
    NSString *wrapped = [NSString stringWithFormat:
        @"export PATH=%@/usr/bin:%@/bin:%@/usr/sbin:%@/sbin:/usr/bin:/bin:/usr/sbin:/sbin; %@",
        prefix, prefix, prefix, prefix, command];

    NSString *sh = IOSPYPath(@"/bin/sh");
    const char *argv[] = {sh.UTF8String, "-c", wrapped.UTF8String, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, sh.UTF8String, NULL, NULL, (char *const *)argv, environ);
    if (rc != 0) {
        return 1;
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != pid) {
        return 1; // never reaped the child, don't claim success
    }
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
}

static int cmdRestartDaemon(void) {
    // Reload through launchd; fall back to a fresh bootstrap if it isn't loaded.
    NSString *plist = IOSPYPath(@"/Library/LaunchDaemons/com.ioscpy.daemon.plist");
    NSString *cmd = [NSString stringWithFormat:
        @"launchctl kickstart -k system/com.ioscpy.daemon 2>/dev/null || launchctl bootstrap system %@",
        plist];
    return runShell(cmd);
}

static int cmdReloadHooks(void) {
    return runShell(@"sbreload 2>/dev/null || killall -9 SpringBoard");
}

static int cmdRepairPermissions(void) {
    NSString *cmd = [NSString stringWithFormat:
        @"chmod 755 %@ %@ 2>/dev/null; chown root:wheel %@ %@ 2>/dev/null",
        IOSPYPath(@"/usr/bin/ioscpyd"), IOSPYPath(@"/usr/bin/ioscpyctl"),
        IOSPYPath(@"/usr/bin/ioscpyd"), IOSPYPath(@"/usr/bin/ioscpyctl")];
    return runShell(cmd);
}

static int cmdExportDiagnostics(void) {
    NSString *log = IOSPYPath(@"/var/log/ioscpy");
    NSString *out = @"/tmp/ioscpy-diagnostics.tar.gz";
    NSString *cmd = [NSString stringWithFormat:@"tar czf %@ %@ 2>/dev/null", out, log];
    int rc = runShell(cmd);
    if (rc == 0) {
        printf("%s\n", out.UTF8String);
    }
    return rc;
}

static int cmdLanEnable(NSString *bindAddress) {
    struct in_addr parsed;
    if (inet_pton(AF_INET, bindAddress.UTF8String, &parsed) != 1 ||
        [bindAddress isEqualToString:@"127.0.0.1"]) {
        fprintf(stderr, "lan-enable requires a non-loopback IPv4 bind address\n");
        return 2;
    }
    NSDictionary *config = @{@"BindAddress": bindAddress};
    if (![config writeToFile:kLanConfigPath atomically:YES]) {
        fprintf(stderr, "could not write %s\n", kLanConfigPath.UTF8String);
        return 1;
    }
    runShell([NSString stringWithFormat:@"chmod 600 %@; chown mobile:mobile %@",
                                         kLanConfigPath, kLanConfigPath]);
    int rc = cmdRestartDaemon();
    if (rc == 0) {
        printf("LAN enabled on %s:%u\n", bindAddress.UTF8String, IOSPY_DEFAULT_PORT);
        printf("New Macs pair with a four-digit code shown by SpringBoard.\n");
    }
    return rc;
}

static int cmdLanDisable(void) {
    NSDictionary *config = @{@"BindAddress": @"127.0.0.1"};
    if (![config writeToFile:kLanConfigPath atomically:YES]) return 1;
    return cmdRestartDaemon();
}

static int cmdLanStatus(void) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kLanConfigPath];
    if (!config) {
        printf("LAN enabled on 0.0.0.0:%u (default)\n", IOSPY_DEFAULT_PORT);
        return 0;
    }
    NSString *bind = [config[@"BindAddress"] description];
    BOOL enabled = ![bind isEqualToString:@"127.0.0.1"];
    printf("LAN %s on %s:%u\n", enabled ? "enabled" : "disabled",
           bind.UTF8String, IOSPY_DEFAULT_PORT);
    NSDictionary *trust = [NSDictionary dictionaryWithContentsOfFile:kTrustPath];
    printf("trusted Macs: %lu\n", (unsigned long)trust.count);
    return enabled ? 0 : 1;
}

static int cmdTrustClear(void) {
    [[NSFileManager defaultManager] removeItemAtPath:kTrustPath error:nil];
    int rc = cmdRestartDaemon();
    if (rc == 0) printf("cleared all paired Mac trust records\n");
    return rc;
}

static int cmdDisplayRestore(void) {
    uint8_t black = 0;
    int rc = sendPrivilegedMessage(IOSPYMsgDisplayMode,
                                   [NSData dataWithBytes:&black length:1]);
    if (rc == 0) {
        printf("requested physical display restore\n");
    } else {
        fprintf(stderr, "could not reach ioscpyhook; try sbreload\n");
    }
    return rc;
}

static void usage(void) {
    printf("usage: ioscpyctl <command>\n");
    printf("  status              device + daemon + tweak summary\n");
    printf("  capabilities        capability map reported by the daemon\n");
    printf("  print-device-info   jailbreak layout and device facts\n");
    printf("  restart-daemon      reload ioscpyd through launchd\n");
    printf("  reload-hooks        respring to reload the tweak\n");
    printf("  repair-permissions  fix exec bits / ownership\n");
    printf("  export-diagnostics  bundle logs into /tmp\n");
    printf("  lan-enable [ADDR]   enable paired LAN TCP (default 0.0.0.0)\n");
    printf("  lan-disable         return to loopback/USB-only mode\n");
    printf("  lan-status          show LAN configuration without printing token\n");
    printf("  trust-clear         revoke every paired Mac\n");
    printf("  display-restore     emergency exit from remote black-screen mode\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            usage();
            return 2;
        }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        if ([cmd isEqualToString:@"status"]) {
            return cmdStatus();
        } else if ([cmd isEqualToString:@"capabilities"]) {
            return cmdCapabilities();
        } else if ([cmd isEqualToString:@"print-device-info"]) {
            printDeviceInfo();
            return 0;
        } else if ([cmd isEqualToString:@"restart-daemon"]) {
            return cmdRestartDaemon();
        } else if ([cmd isEqualToString:@"reload-hooks"]) {
            return cmdReloadHooks();
        } else if ([cmd isEqualToString:@"repair-permissions"]) {
            return cmdRepairPermissions();
        } else if ([cmd isEqualToString:@"export-diagnostics"]) {
            return cmdExportDiagnostics();
        } else if ([cmd isEqualToString:@"lan-enable"]) {
            NSString *bind = argc >= 3 ? [NSString stringWithUTF8String:argv[2]] : @"0.0.0.0";
            return cmdLanEnable(bind);
        } else if ([cmd isEqualToString:@"lan-disable"]) {
            return cmdLanDisable();
        } else if ([cmd isEqualToString:@"lan-status"]) {
            return cmdLanStatus();
        } else if ([cmd isEqualToString:@"trust-clear"]) {
            return cmdTrustClear();
        } else if ([cmd isEqualToString:@"display-restore"]) {
            return cmdDisplayRestore();
        }
        usage();
        return 2;
    }
}
