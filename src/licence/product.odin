// What papier's licence is to the toolkit's licence package (gt:licence, docs/licence.md): its name in the payload, its
// key's tag, what its signatures cover, its file and its editions. The program checks with it (licence.odin), papiertool
// signs and checks with it (`papiertool licence`), and the licence Worker has the same values (its products/papier.jsonc).
package papier_licence

import licence "gt:licence"

PRODUCT :: licence.Product{
	name           = "papier",
	title          = "Papier",
	version_tag    = "PAPIER1",
	sign_context   = "papier-licence-v1\n",
	file_extension = ".papierlicence",
	// (`papiertool licence keygen` makes the pair; empty until then: no licence of the real key is accepted)
	public_key     = "",
	// (the development pair: its seed is public on purpose, papiertool's dev_seed)
	dev_public_key = "AxUmDVadQ3OHFyeMIrDczTTo63rdjtn3zgMJ6a6QyU0",
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}
