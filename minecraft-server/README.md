# Always-On Minecraft Bedrock Server — Free Forever

A Minecraft server that behaves like Realms: it's online 24/7, nobody has to
"host" it, and either of you can hop on at 3am whether the other is asleep or
not. It runs on Oracle Cloud's Always Free tier, so the ongoing cost is **฿0**.

Works on **phone, tablet, Windows 10/11, Xbox, PlayStation and Switch**.

**Time to set up:** about 15 minutes using the paste-in installer
([`cloud-init.yaml`](cloud-init.yaml), see Step 4), or ~30 doing it by hand.
Most of that is Oracle's signup form, not Minecraft.

---

## How this compares to what you were picturing

| | Realms | Aternos | **This** |
|---|---|---|---|
| Monthly cost | ~฿280 | Free | **Free** |
| Online when you're offline | Yes | **No** — sleeps, then queue | **Yes** |
| Player limit | 10 | ~10 | 10 (raise it if you want) |
| World size limit | Yes | Yes | **No — 50 GB disk** |
| Add mods/plugins later | No | Yes | **Yes** |
| Setup effort | None | None | ~30 min, once |

Aternos is the one that looks like the obvious free answer but isn't: it shuts
down when the last player leaves, and starting it back up means sitting in a
queue. That's the "someone has to host" problem wearing a disguise. This setup
genuinely never sleeps.

---

## Before you start

**You need a credit or debit card.** Oracle uses it to verify you're a real
person. It is not charged, and Always Free resources stay free with no time
limit — but be honest with yourself that a card is involved. If that's a
dealbreaker, skip to [If Oracle doesn't work out](#if-oracle-doesnt-work-out).

**Two things that will save you an hour of frustration:**

1. **Pick Singapore as your home region.** You cannot change it later without
   making a new account. Singapore gives you roughly 30–50 ms ping from
   Thailand. Picking a US region means a laggy server forever.
2. **Choose Ubuntu, not Oracle Linux.** Mojang only ships an Intel/AMD version
   of the Bedrock server, so on Oracle's ARM chips it runs through a translation
   layer called box64. That layer breaks on Oracle Linux's ARM kernel, which
   uses 64 KB memory pages. Ubuntu uses 4 KB pages and works fine.

> **Sizing note (August 2026):** Oracle quietly halved the free ARM allowance on
> 15 June 2026, from 4 CPUs / 24 GB down to **2 CPUs / 12 GB**, and began
> terminating over-limit instances from **18 August 2026**. The steps below use
> 2/12 so you stay inside the free allowance permanently. Don't be tempted by
> the older 4/24 guides you'll find online — those instances are being killed.

---

## Step 1 — Create the Oracle account

1. Go to <https://www.oracle.com/cloud/free/> and click **Start for free**.
2. Enter your details. **Home region: Singapore.** Take your time on this one —
   it's permanent.
3. Verify by card. You'll land on the Oracle Cloud dashboard.
4. If you ever see an **Upgrade to Paid** banner, ignore it. Always Free stays
   free as long as you only use Always Free–eligible shapes, which is what we do.

---

## Step 2 — Create the server VM

From the dashboard: **☰ Menu → Compute → Instances → Create Instance**.

| Field | Value |
|---|---|
| Name | `minecraft` |
| Image | **Canonical Ubuntu 24.04** (click *Change image*) |
| Shape | **VM.Standard.A1.Flex** (click *Change shape* → *Ampere*) |
| OCPUs | **2** |
| Memory | **12 GB** |
| Boot volume | 50 GB |

Confirm it says **"Always Free eligible"** next to the shape before continuing.

**SSH keys:** choose *Generate a key pair for me* and **download both files**.
You cannot download them again. Save the private key somewhere safe, e.g.
`~/.ssh/mc-server`.

Click **Create**. Wait for the state to go from PROVISIONING to **RUNNING**,
then copy the **Public IP address** shown on the instance page.

> **"Out of host capacity"?** This is the one genuinely annoying part of
> Oracle's free tier — the free ARM capacity in a region can be exhausted. Try a
> different Availability Domain (AD-1, AD-2, AD-3) from the dropdown, and retry
> every few hours. It usually clears within a day.

### Make the IP permanent

By default Oracle hands out an ephemeral IP that **changes when the VM
reboots** — which would silently break your saved server entry. Pin it:

**Instance page → Resources → Attached VNICs → click the VNIC → IPv4 Addresses
→ ⋮ → Edit → Public IP → No Public IP → Reserved Public IP → Create new.**

---

## Step 3 — Open the port in Oracle's firewall

Bedrock uses **UDP port 19132**. Not TCP. Getting this wrong is the single most
common reason a server looks dead when it's actually running perfectly.

From your instance page: click the **subnet** link → click the **Default
Security List** → **Add Ingress Rules**:

| Field | Value |
|---|---|
| Source Type | CIDR |
| Source CIDR | `0.0.0.0/0` |
| IP Protocol | **UDP** |
| Destination Port Range | `19132` |

Save. There's a second firewall *inside* the VM too — the setup script in the
next step handles that one for you.

---

## Step 4 — Install and start the server

> ### 🚀 Shortcut: skip this step entirely
>
> If you paste **[`cloud-init.yaml`](cloud-init.yaml)** into Oracle's
> *Show advanced options → Management → Initialization script* box while
> creating the VM in Step 2, the server installs itself as the machine boots.
> Edit the two `EDIT ME` lines first (server name, your gamertag).
>
> No SSH, no terminal, no commands. Wait ~5 minutes after the instance says
> RUNNING, then go straight to Step 5 and connect. You'd only come back here if
> something didn't work.

### The manual way

SSH in from your computer (Terminal on Mac/Linux, PowerShell on Windows):

```bash
chmod 600 ~/.ssh/mc-server              # Mac/Linux only, one time
ssh -i ~/.ssh/mc-server ubuntu@YOUR_SERVER_IP
```

Then, on the VM:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/chainsukritthikan-lab/safebite.git
cd safebite/minecraft-server
chmod +x setup.sh backup.sh
./setup.sh
```

`setup.sh` installs Docker, opens the VM's internal firewall, adds swap, and
schedules nightly backups. It's safe to re-run if anything goes sideways.

Now set your server name and allowlist:

```bash
nano .env
```

At minimum, put your Xbox gamertag in `OPS=` so you have admin rights. Save with
`Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

The allowlist starts **off** so you can both get in the first time — locking it
down is Step 6, right after you've joined.

Start it:

```bash
docker compose up -d
docker compose logs -f
```

First boot downloads the server and generates the world — give it 2–5 minutes.
When you see `Server started.`, you're live. Press `Ctrl+C` to stop watching the
logs (that doesn't stop the server).

---

## Step 5 — Join

Full per-device instructions, including consoles, are in **[JOINING.md](JOINING.md)**.

The short version for phone and Windows:

**Play → Servers tab → Add Server**

| Field | Value |
|---|---|
| Server Name | SafeBite SMP |
| Server Address | your VM's public IP |
| Port | 19132 |

Xbox, PlayStation and Switch can't add servers directly — they need a small
one-time DNS workaround, which JOINING.md walks through.

---

## Step 6 — Add your friend and lock the door

Bedrock identifies players by a hidden numeric **XUID**, not their gamertag, so
the allowlist needs both. Rather than hunting XUIDs down manually, let the
server tell you:

1. Leave `ALLOW_LIST=false` (the default) so the door is open for a moment.
2. Have your friend join once.
3. Find their XUID in the log:

   ```bash
   docker compose logs | grep -i "Player connected"
   ```

   You'll see something like
   `Player connected: FriendTag, xuid: 2535498765432109`.
4. Add them to `.env`, set `ALLOW_LIST=true`, and restart:

   ```
   ALLOW_LIST=true
   ALLOW_LIST_USERS=YourTag:2535412345678901,FriendTag:2535498765432109
   ```

   ```bash
   docker compose up -d
   ```

Do turn the allowlist back on. Bedrock servers get found by automated scanners
within days, and without it anyone who finds the IP can wander into your world.

---

## Running it day to day

```bash
cd ~/safebite/minecraft-server

docker compose logs -f          # watch what's happening
docker compose restart          # restart the server
docker compose down             # stop it
docker compose up -d            # start it (also applies .env changes)

docker attach mc-bedrock        # server console — type commands directly
                                # detach WITHOUT stopping it: Ctrl+P then Ctrl+Q

./backup.sh                     # back up right now
ls -lh backups/                 # list backups
```

**Careful:** in `docker attach`, pressing `Ctrl+C` stops the server. Always
detach with `Ctrl+P` `Ctrl+Q`.

Backups run nightly at 05:00 and keep 14 days. The server pauses for a few
seconds during each one. Restore instructions are in the comments at the bottom
of `backup.sh`.

---

## If the server won't start

**Container keeps restarting, log says `SIGILL` or `illegal instruction`**

box64 can't translate Mojang's binary on your specific ARM chip. Not fixable by
configuration — switch to the fallback, which runs a Java-Edition server that
Bedrock devices can still join normally (your friend does *not* need to buy a
Java account):

```bash
docker compose down
docker compose -f docker-compose.geyser.yml up -d
```

You'll connect exactly the same way, same IP and port. See the comments at the
top of `docker-compose.geyser.yml` for the small tradeoffs.

**Server runs fine but nobody can connect**

Almost always the firewall. Check both halves:

```bash
sudo iptables -L INPUT -n --line-numbers | grep 19132   # inside the VM
docker compose ps                                        # is it actually up?
```

If the iptables line is missing, re-run `./setup.sh`. If it's present, the
Oracle-side ingress rule from Step 3 is missing, or it was created as TCP
instead of UDP — go back and check.

**Can't find the server on the same home Wi-Fi**

Some routers block a device from reaching the internet and coming back to
itself. Testing from mobile data usually proves the server is fine.

**Ping feels bad**

Confirm the VM is actually in Singapore, and lower `VIEW_DISTANCE` in `.env` to
`8` — on 2 cores that helps more than you'd expect.

---

## If Oracle doesn't work out

If the capacity errors never clear, or you'd rather not hand over a card, the
next-best always-on options:

- **Minecraft Realms** — ~฿280/mo, zero setup, official, works on every device.
  Genuinely the least hassle if you don't mind paying.
- **A cheap VPS** — Hetzner or Contabo run ~฿150–250/mo. Every file here works
  unchanged; skip to Step 4 and use the provider's firewall for Step 3.
- **An old PC or Raspberry Pi at home** — free, but it has to stay powered on,
  and you'd want a tunnel like [playit.gg](https://playit.gg) to avoid port
  forwarding. Realistically this is "you host it" again, just automated.

---

## What's in this folder

| File | Purpose |
|---|---|
| `cloud-init.yaml` | **Easiest path** — paste into Oracle at VM creation, installs itself. |
| `docker-compose.yml` | The Bedrock server. This is the main one. |
| `docker-compose.geyser.yml` | Fallback if box64 fails on your ARM chip. |
| `.env.example` | Settings template — copy to `.env` and edit. |
| `setup.sh` | One-time VM bootstrap: Docker, firewall, swap, cron. |
| `backup.sh` | Nightly world backup with 14-day retention. |
| `JOINING.md` | How to connect from each device, consoles included. |

---

## Sources

- [Oracle quietly halves Free Tier Ampere A1 limits](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/) — the 2 CPU / 12 GB change and the 18 Aug 2026 termination date
- [box64 issue #335 — 64k page size on Oracle Ampere](https://github.com/ptitSeb/box64/issues/335) — why Ubuntu and not Oracle Linux
- [itzg/docker-minecraft-bedrock-server](https://github.com/itzg/docker-minecraft-bedrock-server) — the server image and its settings
- [GeyserMC](https://geysermc.org/) — Bedrock-to-Java bridge used by the fallback
- [BedrockConnect](https://github.com/vworks-cc/BedrockConnect-DNS) — console joining
