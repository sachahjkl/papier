# secrets

SOPS files, encrypted for the maintainer's age key (`.sops.yaml`). Read one with `sops -d secrets/production.yaml`.

- `production.yaml`: `UPDATE_SIGNING_KEY`, the private half of papier's update key (Ed25519, base64url of its 32 bytes).
  The release workflow has it as the repository's secret of the same name: `papiertool package` signs the update
  manifests with it. Its public half is `PRODUCT.public_key` in `src/update/product.odin`.
