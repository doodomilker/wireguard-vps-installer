# Cloud Firewall Configuration

> The script only configures the **OS-level firewall (iptables/nftables)**.  
> Most cloud providers have a **separate security layer** in their web console that must be opened manually.  
> If clients can't connect, **99% of the time this is the reason**.

## AWS Lightsail

1. Instance → Networking tab
2. "+ Add rule" under "Firewall"
3. Application: **Custom**
4. Protocol: **UDP**
5. Port: **51820**
6. Save

## AWS EC2

1. EC2 → Security Groups → select your instance's SG
2. "Edit inbound rules" → "Add rule"
3. Type: **Custom UDP**
4. Port range: **51820**
5. Source: `0.0.0.0/0` (or restrict to your IP)
6. Save

## DigitalOcean

1. Networking → Firewalls → your firewall (or create one)
2. Inbound Rules → "Add rule"
3. Type: **Custom**
4. Protocol: **UDP**
5. Ports: **51820**
6. Sources: All IPv4 / All IPv6 (or restrict)
7. Apply → assign to droplet

## Vultr

1. Firewall → Add Firewall Group (or edit existing)
2. "Add rule" → Protocol: **UDP**, Port: **51820**, Subnet: `0.0.0.0/0`
3. Save → link to instance

## Hetzner Cloud

1. Firewalls → Create firewall (or edit)
2. "Add rule" → Protocol: **UDP**, Port: **51820**, Source IPs: `0.0.0.0/0`
3. Apply to your server

## Aliyun (阿里云)

1. ECS 控制台 → 安全组 → 选择实例的安全组 → 配置规则
2. 入方向 → 手动添加 → 协议端口：**UDP:51820**
3. 授权对象：`0.0.0.0/0`（或限制你的 IP）
4. 保存

## Tencent Cloud (腾讯云)

1. CVM 控制台 → 安全组 → 选择实例的安全组
2. 入站规则 → 添加规则 → 类型：**自定义**，协议端口：**UDP:51820**
3. 来源：`0.0.0.0/0`
4. 完成

## Google Cloud Platform (GCE)

GCP default firewall blocks everything. Either:
1. VPC network → Firewall → "Create firewall rule" with target `wg-server`, UDP 51820
2. Or assign the `default-allow-ssh` tag + add a new rule for UDP 51820

## Azure

1. VM → Networking → "Add inbound port rule"
2. Source: Any / Source port: *
3. Destination: Any / Destination port: **51820**
4. Protocol: **UDP**
5. Action: Allow

## Oracle Cloud

Oracle Cloud has TWO firewalls: iptables (handled by script) AND a Security List / Network Security Group.

1. Instance → Subnet → Security List → "Add Ingress Rules"
2. Source CIDR: `0.0.0.0/0`, Protocol: **UDP**, Destination Port: **51820**
3. Save

## Linode

1. Firewalls → Create firewall (or edit)
2. Inbound → "Add rule" → Protocol: **UDP**, Ports: **51820**
3. Devices → assign to your Linode

## Quick diagnostic

If clients can't connect:

```bash
# From VPS — should see UDP 51820 listening
sudo ss -lntu | grep 51820

# From VPS — firewall rules
sudo iptables -L INPUT -n | grep 51820

# From CLIENT machine — test reachability
nc -uvz YOUR_VPS_IP 51820
# or
nc -uv YOUR_VPS_IP 51820
# then type anything and check if you get ICMP unreachable
```

If `ss` shows it's listening but `nc` fails → **your cloud security group is closed**. This is the most common issue.
