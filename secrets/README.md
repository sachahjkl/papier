# secrets

SOPS files, encrypted for the maintainer's age key (`.sops.yaml`). Read one with `sops -d secrets/production.yaml`. The
toolkit's [docs/licence.md](https://github.com/sachahjkl/gui_toolkit/blob/main/docs/licence.md) says the licence's whole
flow.

| File | Use |
|---|---|
| `production.yaml` | the update key, the licence's signing key and the live Paddle keys |
| `development.yaml` | the licence's development pair (its seed is public on purpose: `papiertool`'s `dev_seed`), the sandbox's Paddle keys; made when the shop is set up |

Keys:

| Key | What it is |
|---|---|
| `UPDATE_SIGNING_KEY` | the private half of papier's update key (Ed25519, base64url of its 32 bytes). The release workflow has it as the repository's secret of the same name: `papiertool package` signs the update manifests with it. Its public half is `PRODUCT.public_key` in `src/update/product.odin`. |
| `LICENSE_PRIVATE_KEY` | the licence's signing key, the 32-byte Ed25519 seed, base64url: the line of `private.key` that is not a `#` comment (`papiertool licence keygen`). Its public half is `PRODUCT.public_key` in `src/licence/product.odin`. |
| `PADDLE_WEBHOOK_SECRET` | Paddle > Developer tools > Notifications > the destination > Secret key (`pdl_ntfset_...`) |
| `PADDLE_API_KEY` | Paddle > Developer tools > Authentication > API keys (server side, `customer.read`) |
| `ADMIN_TOKEN` | optional: the bearer token of the licence Worker's `/admin/*` |

A key that sets the catalogue up (`papiertool paddle -apply`: product and price rights) does not go to the Worker. Keep it
here only while the set-up lasts (`PADDLE_SETUP_KEY`), revoke it in Paddle, then `sops unset` it.

## Key

The age identity is the maintainer's, outside every repository: `~/.config/sops/age/keys.txt`.

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops secrets/production.yaml                                   # edit
sops set secrets/production.yaml '["LICENSE_PRIVATE_KEY"]' '"…"'   # one value, no editor
```

## The licence Worker's secrets

```sh
papiertool licence secrets secrets/production.yaml <toolkit>/licence-worker/secrets.env
papiertool licence secrets secrets/development.yaml <toolkit>/licence-worker/secrets.sandbox.env
```

The tool decrypts with `sops --decrypt --output-type dotenv`, keeps only the Worker's secrets, writes a file readable by
you only, and refuses a path that git does not ignore. It prints the names, never a value. Remove the files after the deploy.
