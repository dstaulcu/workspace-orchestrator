# Concept art

`assets/concept.jpg` is the concept art (README banner, startup splash and About box). It was generated from the prompt below. Keep the prompt here as the baseline so future variations (a new size, a seasonal tweak, a different model) start from the same look.

## Baseline prompt

> Digital illustration in a Western-meets-cyberpunk style featuring bold arched display lettering at the top reading "WORKSPACE WRANGLER" in warm golden-yellow with a dark navy/charcoal outline and subtle glowing accents. In the center, a rugged cowboy wearing a brown cowboy hat, dark visor/goggles, plaid button-up shirt, blue jeans, belt with buckle, and boots rides a sleek, metallic silver-and-blue robotic bucking bronco with glowing cyan eyes and mechanical joints. The cowboy holds the reins in his right hand and swings a glowing blue-and-gold energy lasso with his left hand, herding floating digital distraction icons (notification bells, chat bubbles, browser windows, and alert triangles) into the loop. Set in a desert canyon landscape with mesa buttes and neon-outlined saguaro cacti on a glowing cyan perspective grid floor, with digital tumbleweeds made of tangled wire/data threads kicking up dust and glowing particles. Background features subtle translucent code snippets, binary numbers, and terminal-style lines fading into a sunset sky transitioning from warm orange-gold to deep teal and navy. Crisp linework, vibrant contrast between warm desert tones and cool electric cyan highlights.

## Where it is used

- README banner (`assets/concept.jpg`).
- Startup splash and the About box (the **About** link beside the Help links, or Settings > About Workspace Wrangler...): `assets/splash.jpg`, a 640 px wide copy. Click the art in the About box to open the full-size image.
- First-run folder dialog: `assets/mark.png`, a rider-only square crop.
- The app icon (`assets/app.ico`, drawn by `tools/New-AppIcon.ps1`) reuses the art's palette: night sky to sunset glow, neon cyan grid and ring, the hat with a glowing cyan visor. Keep the two in step if either changes.
- GitHub social preview: `assets/social-preview.jpg` (1280 x 640). GitHub has no API for this, so upload it by hand in the repository's Settings > General > Social preview.

`tools/New-ArtAssets.ps1` regenerates the three derived images from `concept.jpg`; run it after replacing the concept art.

## Notes

- Generated with Gemini; 16:9, 1376 x 768 JPEG.
- The idea it illustrates: the rider herds notification and window "distractions" into one loop, which is what the picker does for your project windows.
- Image models tend to garble small text (the code snippets in the background) and the lettering; regenerate or touch up if the title text matters.
- Palette: golden-yellow title, navy/charcoal outline, warm orange-gold sunset to deep teal, electric cyan accents.
