#!/usr/bin/env python3
import socket
import sys
import json
import time
import argparse
import traceback

# Built-in lightweight lists
AD_TRACKER_DOMAINS = {
    "doubleclick.net", "google-analytics.com", "adservice.google.com",
    "adnxs.com", "adsrvr.org", "quantserve.com", "scorecardresearch.com",
    "amplitude.com", "mixpanel.com", "telemetry.mozilla.org",
    "adcolony.com", "applovin.com", "unityads.unity3d.com"
}

ADULT_DOMAINS = {
    "pornhub.com", "xvideos.com", "xnxx.com", "redtube.com", "youporn.com",
    "chaturbate.com", "stripchat.com", "livejasmin.com", "onlyfans.com"
}

def parse_domain(data, offset=12):
    labels = []
    curr = offset
    try:
        while True:
            length = data[curr]
            if length == 0:
                curr += 1
                break
            labels.append(data[curr+1 : curr+1+length].decode('utf-8', errors='ignore'))
            curr += 1 + length
        domain = '.'.join(labels)
        qtype = int.from_bytes(data[curr : curr+2], byteorder='big')
        return domain, qtype, curr + 4
    except Exception:
        return "", 0, 0

def get_qtype_name(qtype):
    mapping = {1: "A", 28: "AAAA", 15: "MX", 16: "TXT", 5: "CNAME", 2: "NS", 12: "PTR", 6: "SOA"}
    return mapping.get(qtype, f"TYPE_{qtype}")

def match_domain_rule(domain, rules):
    custom_rules = rules.get("custom_rules", [])
    for rule in custom_rules:
        r_domain = rule.get("domain", "")
        if not r_domain:
            continue
        if domain == r_domain or domain.endswith("." + r_domain):
            return rule.get("action"), rule.get("value")

    if rules.get("block_ads", False):
        for ad_domain in AD_TRACKER_DOMAINS:
            if domain == ad_domain or domain.endswith("." + ad_domain):
                return "block", None

    if rules.get("block_adult", False):
        for adult_domain in ADULT_DOMAINS:
            if domain == adult_domain or domain.endswith("." + adult_domain):
                return "block", None

    return None, None

def build_nxdomain_response(request, question_end):
    response_header = request[:2] + b'\x81\x83' + b'\x00\x01\x00\x00\x00\x00\x00\x00'
    return response_header + request[12:question_end]

def build_a_response(request, question_end, ip_str):
    response_header = request[:2] + b'\x81\x80' + b'\x00\x01\x00\x01\x00\x00\x00\x00'
    ip_bytes = socket.inet_aton(ip_str)
    answer = b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + ip_bytes
    return response_header + request[12:question_end] + answer

def send_log_unix(pair_id, log_socket_path, domain, qtype_name, status, answer, duration_ms):
    if not log_socket_path:
        return
    log_data = {
        "pair_id": pair_id,
        "domain": domain,
        "type": qtype_name,
        "status": status,
        "answer": answer,
        "duration": duration_ms,
        "timestamp": int(time.time())
    }
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.sendto(json.dumps(log_data).encode('utf-8'), log_socket_path)
        sock.close()
    except Exception as e:
        print(f"Failed to send log to unix socket {log_socket_path}: {e}", file=sys.stderr)

def main():
    parser = argparse.ArgumentParser(description="DNS Filtering Proxy")
    parser.add_argument("--id", required=True, help="VPN Pair ID")
    parser.add_argument("--upstream", default="1.1.1.1", help="Comma-separated default upstream DNS servers")
    parser.add_argument("--rules", required=True, help="Path to rules JSON file")
    parser.add_argument("--log-socket", help="Unix socket path for receiving UDP/domain logs")
    parser.add_argument("--port", type=int, default=53, help="Port to listen on (default: 53)")
    args = parser.parse_args()

    default_upstream = [ip.strip() for ip in args.upstream.split(",") if ip.strip()]
    if not default_upstream:
        default_upstream = ["1.1.1.1"]

    print(f"Starting DNS proxy for '{args.id}' on port {args.port}...", flush=True)
    print(f"Default Upstream DNS: {default_upstream}", flush=True)
    print(f"Rules path: {args.rules}", flush=True)

    dns_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        dns_sock.bind(("0.0.0.0", args.port))
    except Exception as e:
        print(f"Critical error: Failed to bind to port {args.port}: {e}", file=sys.stderr, flush=True)
        sys.exit(1)

    while True:
        try:
            data, addr = dns_sock.recvfrom(4096)
            if len(data) < 12:
                continue

            start_time = time.time()
            domain, qtype, question_end = parse_domain(data)
            qtype_name = get_qtype_name(qtype)

            if not domain or question_end <= 0:
                continue

            # Dynamic rules loading
            rules = {"enabled": False, "block_ads": False, "block_adult": False, "custom_rules": []}
            try:
                with open(args.rules, "r") as f:
                    rules = json.load(f)
            except Exception:
                pass

            # Dynamic upstream selection from rules file
            upstream_str = rules.get("upstream_dns", "")
            if upstream_str:
                upstream_dns = [ip.strip() for ip in upstream_str.split(",") if ip.strip()]
            else:
                upstream_dns = default_upstream
            if not upstream_dns:
                upstream_dns = ["1.1.1.1"]

            if not rules.get("enabled", False):
                # DNS Filtering is disabled, forward to upstream
                resolved = False
                for upstream in upstream_dns:
                    try:
                        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        upstream_sock.settimeout(2.0)
                        upstream_sock.sendto(data, (upstream, 53))
                        resp, _ = upstream_sock.recvfrom(4096)
                        dns_sock.sendto(resp, addr)
                        upstream_sock.close()
                        resolved = True
                        break
                    except Exception:
                        continue
                if not resolved:
                    servfail = data[:2] + b'\x81\x82' + b'\x00\x01\x00\x00\x00\x00\x00\x00' + data[12:question_end]
                    dns_sock.sendto(servfail, addr)
                continue

            # Check matching rules
            action, value = match_domain_rule(domain, rules)
            duration_ms = int((time.time() - start_time) * 1000)

            if action == "block":
                resp = build_nxdomain_response(data, question_end)
                dns_sock.sendto(resp, addr)
                send_log_unix(args.id, args.log_socket, domain, qtype_name, "blocked", "NXDOMAIN", duration_ms)
            elif action == "redirect" and value:
                if qtype == 1:
                    resp = build_a_response(data, question_end, value)
                    dns_sock.sendto(resp, addr)
                    send_log_unix(args.id, args.log_socket, domain, qtype_name, "redirected", value, duration_ms)
                else:
                    resp = build_nxdomain_response(data, question_end)
                    dns_sock.sendto(resp, addr)
                    send_log_unix(args.id, args.log_socket, domain, qtype_name, "redirected", "NXDOMAIN", duration_ms)
            else:
                # Forward to upstream
                resolved = False
                for upstream in upstream_dns:
                    try:
                        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        upstream_sock.settimeout(2.0)
                        upstream_sock.sendto(data, (upstream, 53))
                        resp, _ = upstream_sock.recvfrom(4096)
                        dns_sock.sendto(resp, addr)
                        upstream_sock.close()
                        resolved = True
                        
                        ans_ip = "Resolved"
                        duration_ms = int((time.time() - start_time) * 1000)
                        send_log_unix(args.id, args.log_socket, domain, qtype_name, "resolved", ans_ip, duration_ms)
                        break
                    except Exception:
                        continue
                if not resolved:
                    servfail = data[:2] + b'\x81\x82' + b'\x00\x01\x00\x00\x00\x00\x00\x00' + data[12:question_end]
                    dns_sock.sendto(servfail, addr)

        except Exception as e:
            print(f"Error handling DNS query: {e}", file=sys.stderr)
            traceback.print_exc()
            time.sleep(0.1)

if __name__ == "__main__":
    main()
