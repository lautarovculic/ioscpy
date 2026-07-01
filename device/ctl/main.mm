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
        @"host_version": @"0.1.5",
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

static void usage(void) {
    printf("usage: ioscpyctl <command>\n");
    printf("  status              device + daemon + tweak summary\n");
    printf("  capabilities        capability map reported by the daemon\n");
    printf("  print-device-info   jailbreak layout and device facts\n");
    printf("  restart-daemon      reload ioscpyd through launchd\n");
    printf("  reload-hooks        respring to reload the tweak\n");
    printf("  repair-permissions  fix exec bits / ownership\n");
    printf("  export-diagnostics  bundle logs into /tmp\n");
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
        }
        usage();
        return 2;
    }
}
