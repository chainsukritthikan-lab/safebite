# How to Join

Send this page to your friend. They need two things from you:

- **Server IP:** `______________________` (your Oracle VM's public IP)
- **Port:** `19132`

Everyone must be on **Minecraft Bedrock Edition** — the version on phones,
Windows 10/11, and consoles. The Java Edition launcher on PC will not connect.

---

## Android / iPhone / iPad / Fire tablet

1. Open Minecraft → **Play**
2. Tap the **Servers** tab at the top
3. Scroll to the bottom → **Add Server**
4. Fill in:
   - Server Name: `SafeBite SMP`
   - Server Address: *the IP*
   - Port: `19132`
5. **Save**, then tap the server to join

It appears in your Servers list from then on — one tap, any time.

---

## Windows 10 / 11

Identical to phone:

**Play → Servers tab → Add Server →** name, IP, port `19132` **→ Save**

> Make sure you're launching **Minecraft for Windows** (the Bedrock one), not
> **Minecraft: Java Edition**. If your launcher offers both, pick the Bedrock
> tile. Java Edition cannot join this server.

---

## Xbox, PlayStation and Nintendo Switch

Consoles can't add custom servers directly — Mojang only exposes their four
"Featured Servers". The standard workaround is **BedrockConnect**: you point the
console's DNS at a small public service, and the Featured Server slots turn into
a menu where you can type any IP.

This is a well-established community tool, but it does mean your console's DNS
lookups route through a third party. If that bothers you, play on phone or PC
instead, or use the LAN trick at the bottom.

### Step 1 — Change the console's DNS

Use `104.238.130.180` as the **primary** DNS and `1.1.1.1` as the secondary.
(Current alternates are listed at <https://bedrockconnect.app>.)

**Xbox**
Settings → General → Network settings → Advanced settings → DNS settings →
**Manual** → enter primary and secondary → save → back out and restart Minecraft

**PlayStation 4 / 5**
Settings → Network → Set Up Internet Connection → pick your connection →
**Custom** → IP Address: Automatic → DHCP Host Name: Do Not Specify →
DNS Settings: **Manual** → enter primary and secondary → MTU: Automatic →
Proxy: Do Not Use

**Nintendo Switch**
System Settings → Internet → Internet Settings → your network → Change Settings
→ DNS Settings → **Manual** → enter primary and secondary → Save

### Step 2 — Join

1. Launch Minecraft and go to the **Servers** tab
2. Select **any** of the featured servers (Lifeboat, Mineplex, etc.)
3. Instead of that server, a BedrockConnect menu appears
4. Choose **Connect to a Server**, enter the IP and port `19132`
5. It's saved in that menu for next time

### If it doesn't work

- Fully close and reopen Minecraft after changing DNS — it caches aggressively
- Try a different BedrockConnect IP from <https://bedrockconnect.app>
- Restart the console
- To undo everything, set DNS back to **Automatic**

---

## Signing in

The server has `ONLINE_MODE=true`, so everyone needs to be signed into a
**Microsoft/Xbox account** in Minecraft. Free to make, and it's what keeps
randoms from joining as you.

If the allowlist is on, the owner has to add each gamertag before it'll let you
in — see Step 6 in [README.md](README.md).

---

## Common problems

**"Unable to connect to world"**

Usually one of three things, in order of likelihood:

1. The IP was typed wrong — it's easy to fat-finger
2. The port isn't `19132`
3. The server is off. Owner runs `docker compose ps` to check.

**It worked yesterday, not today**

The VM's public IP probably changed after a reboot. Reserve it permanently —
Step 2 of [README.md](README.md), "Make the IP permanent".

**"You are not on the allowlist"**

Working exactly as intended — the owner just needs to add you.

**Everyone else is on but I can't get in**

Try mobile data instead of your Wi-Fi. Some routers block traffic that leaves
and comes straight back to the same network.

---

## Playing on the same Wi-Fi (no DNS needed)

If your console is on the same network as a phone or PC that has already joined
the server, the console can often see it under **Friends → LAN Games** without
any DNS setup at all. Worth trying first — it's the least invasive option.
