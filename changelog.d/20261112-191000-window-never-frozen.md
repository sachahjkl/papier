type: Fixed

**The window no longer freezes after a copy** (Linux, Wayland): with NVIDIA's driver, a compositor that held back its word that it showed the window's picture (ShojiWM, counting the window on the wrong screen) left the window without a new picture for good. Papier now presents in a way that never waits, waits for that word a quarter of a second at most, and draws at once after a key or a click (gui_toolkit 0.221.1).
