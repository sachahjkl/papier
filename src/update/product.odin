// What papier is to the toolkit's update package (gt:update, docs/updates.md): its name in the manifests and the release's
// file names, what its signatures cover, and the public half of its update key (papiertool update keygen; the private half
// is in secrets/production.yaml and the release workflow's secret UPDATE_SIGNING_KEY). The program checks with it
// (updates.odin), papiertool signs with it (papiertool package).
package papier_update

import update "gt:update"

PRODUCT :: update.Product{
	name         = "papier",
	sign_context = "papier-update-v1\n",
	public_key   = "Y3GKcVMJsv11SEcIqZp2-A7KAtWbSzoVlZdIQz9fj88",
}
