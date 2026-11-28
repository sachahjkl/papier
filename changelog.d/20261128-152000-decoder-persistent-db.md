type: Fixed

**Image previews stay connected to the active history database.** The image decoder now keeps a persistent database connection instead of reopening `history.db` by path on every click or thumbnail, preventing previews from failing after a bind-mount change and distinguishing a missing image from an unsupported format.
