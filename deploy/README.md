# Deploy `verdikt.gudman.xyz`

DNS already points `verdikt.gudman.xyz` → `75.119.153.252` (same VPS as `forum.gudman.xyz`). What's left: nginx server block, Let's Encrypt cert, upload `slides.html`.

## What gets deployed

```
/opt/verdikt/web/
├── index.html         ← web/index.html   (product landing page)
├── deck.html          ← slides.html      (reveal.js pitch deck)
└── app/
    ├── index.html     ← ui/index.html    (interactive escrow demo, wired to live contracts)
    ├── caselaw.html   ← ui/caselaw.html  (case-law dashboard)
    └── caselaw.json   (snapshot of on-chain rulings)
```

`verdikt.gudman.xyz/` is the product landing; `/app/` is the live demo; `/deck.html` is the deck.

## Re-deploy (run on your laptop, from the repo root)

```bash
scp web/index.html    root@75.119.153.252:/opt/verdikt/web/index.html
scp slides.html       root@75.119.153.252:/opt/verdikt/web/deck.html
scp ui/index.html     root@75.119.153.252:/opt/verdikt/web/app/index.html
scp ui/caselaw.html   root@75.119.153.252:/opt/verdikt/web/app/caselaw.html
```

No nginx reload needed for content changes (static files, `try_files`).

## One-time setup (run on the VPS)

```bash
# 1. Create the web root
sudo mkdir -p /opt/verdikt/web
sudo chown -R $USER:$USER /opt/verdikt

# 2. Drop the nginx server block
sudo cp /tmp/nginx-verdikt.gudman.xyz.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/nginx-verdikt.gudman.xyz.conf \
            /etc/nginx/sites-enabled/

# 3. Issue the Let's Encrypt cert (auto-edits the server block)
sudo certbot --nginx -d verdikt.gudman.xyz

# 4. Reload nginx
sudo nginx -t && sudo systemctl reload nginx
```

## Upload the deck (run on your laptop)

```bash
# From the repo root:
scp slides.html                           root@75.119.153.252:/opt/verdikt/web/index.html
scp deploy/nginx-verdikt.gudman.xyz.conf  root@75.119.153.252:/tmp/
```

If your SSH user isn't `root`, swap accordingly and prepend `sudo` to the install commands.

## Re-deploy after editing `slides.html`

```bash
scp slides.html root@75.119.153.252:/opt/verdikt/web/index.html
```

No nginx reload needed for content changes. `slides.html` is self-contained — reveal.js loads from `cdn.jsdelivr.net` at runtime.

## Verify

```bash
curl -sI https://verdikt.gudman.xyz/ | head -5
# expect: HTTP/2 200, content-type: text/html
```

Open `https://verdikt.gudman.xyz` — arrow keys navigate slides, `f` toggles fullscreen, `?` shows help.

## Source of truth

- **`slides.html`** — the deployable single-file deck (reveal.js + markdown plugin, all content embedded inline).
- **`DECK.md`** — the same content in Marp-flavored Markdown. Optional alternate render path: `npx @marp-team/marp-cli DECK.md --html -o DECK.html` (first run downloads ~150 MB; not required for deployment).

Both kept in sync. Edit either, but `slides.html` is what ships.
