#!/usr/bin/env python3
# drive the qemu serial console (a unix socket from start_qemu with QEMU_SERIAL_SOCK):
# wait for the login prompt, log the baked user in, prime sudo with the password so
# the script can use plain `sudo`, then run the shell script piped on stdin and print
# everything it emits. the script prints its own markers; scenarios assert on the
# output. usage: serial.py <socket> <user> <password> [login-timeout-seconds]
import os, socket, sys, time, re

sock, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]
login_to = int(sys.argv[4]) if len(sys.argv) > 4 else 720
script = sys.stdin.read()
B = [""]

s = socket.socket(socket.AF_UNIX)
for _ in range(login_to):
    try:
        s.connect(sock); break
    except OSError:
        time.sleep(1)
else:
    print("serial: could not connect to %s" % sock, file=sys.stderr); sys.exit(2)
s.settimeout(1)

def pump(t):
    end = time.time() + t
    while time.time() < end:
        try:
            d = s.recv(4096)
        except socket.timeout:
            continue
        if d:
            B[0] += d.decode("latin1", "replace")

def wait(pat, t):
    end = time.time() + t
    while time.time() < end:
        pump(0.5)
        if re.search(pat, B[0]):
            return True
    return False

strip = lambda x: re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-~]|\r", "", x)

if not wait(r"login:", login_to):
    print("serial: never reached login prompt", file=sys.stderr)
    print(strip(B[0])[-600:]); sys.exit(3)
s.sendall(user.encode() + b"\n"); wait(r"[Pp]assword:", 30)
s.sendall(pw.encode() + b"\n"); wait(r"[\$#] ", 40)
# prime the sudo timestamp so the piped script can use plain `sudo` (no password).
s.sendall(b"echo " + pw.encode() + b" | sudo -S -v 2>/dev/null\n"); time.sleep(2); pump(2)

B[0] = ""
# run the script as a heredoc, then a done sentinel built so its own echo (which
# contains the $(()) form) cannot match the wait pattern (which sees only output).
s.sendall(b"bash <<'EOSCRIPT'\n" + script.encode() + b"\nEOSCRIPT\n")
s.sendall(b"echo SERIALDONE$((99))\n")
if not wait(r"SERIALDONE99\b", int(os.environ.get("SERIAL_SCRIPT_TIMEOUT", "600"))):
    print("serial: script did not finish", file=sys.stderr)
print(strip(B[0]))
