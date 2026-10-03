# Easel

A small Mac app for photographing paintings. Open a photo (RAW or JPG), drag the four corners onto the painting, pick the canvas size, and save two JPGs: a full-size one and a smaller one for the web.

## Set it up (one time, about 10 minutes)

1. **Install Apple's developer tools.** Open Terminal (in Applications > Utilities) and run:

   ```
   xcode-select --install
   ```

   Click Install in the window that pops up. (If you already installed Xcode, you can skip this.)

2. **Build the app.** In Terminal, go to this folder and run the build script. The easiest way: type `cd ` (with a space), drag the Easel folder into the Terminal window, press Return, then run:

   ```
   bash make-app.sh
   ```

3. A Finder window opens showing **Easel.app**. Drag it into your Applications folder. Done.

*Prefer Xcode?* Double-click `Package.swift` to open the project in Xcode, then press ⌘R to run it.

## Using it

1. Click **Add Photos** (top right, or ⌘O), or drag files or a whole folder into the window. Plug in a camera memory card and Easel asks if you want to pick photos from it. Click the ones you want (or **Select This Day**, or shift-click a run of them), then **Import**. Nothing is picked until you choose. Easel copies them into your **Imported Photos** folder (Pictures > Easel > Imported Photos, one folder per day), so they stay after you eject the card. Photos you imported before are marked "Imported before" and aren't copied twice. If the card was already plugged in, or you clicked Not Now, use **File > Import from Memory Card** (⇧⌘I). You can turn off the question in Settings > Export. If you shot RAW + JPG, Easel uses the RAW.
2. Easel tries to **find the painting's edges** on its own. Drag any corner to fix it. A magnifier shows up while you drag so you can place it exactly. **Auto-Find Edges** tries again, and **Reset Corners** starts over with a plain rectangle.
3. Fill in the **title**, **artist**, **date** (year, and month if you know it), and anything else you use (medium, record ID), and pick the **canvas size**. Portrait or landscape is guessed for you. If no size is picked yet, Easel picks the one closest to the painting's shape and tells you. When two sizes have the same shape (like 8x10 and 16x20), it picks the one you've used most. Leave Artist or Medium empty to use your defaults from Settings (shown in grey).
4. Press **After** (or ⌘B) to check the straightened result.
5. Check the **file name**. Pick a style from the menu (like Title_Date_Artist), or type a name for just this photo. Below that, **Save to** shows where the files will go. Click the folder name to switch to a recent folder, or choose a new one.
6. Press **Save JPGs** (⌘S). A title and canvas size are required. If one is missing, Easel says so and marks it in red. Easel saves both files and moves to the next photo. When you come back to a saved photo, the panel shows a green **Saved** check and the button changes to **Save Again**, which makes another copy. If you change anything, the button turns blue again.

Handy keys: ⌘[ and ⌘] go to the previous and next photo, ⌘E finds the edges again.

Easel remembers your photo list. Quit and reopen, and every photo is still there with its corners, info and saved check, and the photo you had open comes back. Right-click a photo and choose **Remove from List** to take it off. This doesn't delete the file. Photos added with Add Photos stay where they are on your Mac. If you move or delete one, Easel takes it off the list next time it opens.

## Color checker

If you have a ColorChecker (like the Calibrite ColorChecker Classic Mini), Easel can fix your photos' colors so the paint looks true to life.

1. At the start of a session, take one photo of the checker in the same spot and light as your paintings, with the same camera settings. Take a new one if the light changes.
2. In Easel, open that photo and turn on **Color checker photo** at the top of the right panel. Easel finds the chart and puts the corners on it. Drag them onto the outer corners of the colored squares (not the black frame) if needed. Each small white square on top should sit inside one color.
3. The panel shows how well it worked: how far off the colors were, how close they are with the fix (under 2 is hard to see), and the chart's squares before and after. The dot in each square is the true color.
4. Photos taken after the checker photo on the same day use its fix automatically, until the next checker photo. Each painting's **Color** menu shows which fix it's using. You can pick a different one or turn it off. Press **After** (⌘B) to see the result. The saved JPGs use it too.

Checker photos have a purple icon in the list and aren't saved as JPGs.

**Charts:** the ColorChecker Classic full size, Mini, Nano and the 24-square page of the ColorChecker Passport all have the same colors. Charts made before 2015 have slightly different colors, so pick that one in the **Chart** menu if yours is older.

**Tips:** light the chart evenly with no glare. Tilting it slightly away from the lights helps. Don't let the white square get too bright. Easel warns you if it's overexposed. The Mini is small, so fill at least a tenth of the photo's width with it.

## Settings

Click **Settings** (the gear, top right), the **More options in Settings** link under the Save button, or press ⌘,.

- **Files:** where memory card photos are copied to, where to save and how files are named (you can change both from the main window too), and your default artist and medium.
- **Export:** quality for the full-size JPG, and the size and quality of the web JPG.
- **Sizes:** add or remove canvas sizes.

### File name blanks

Build names from these pieces, in any order:

| Blank | Becomes |
|---|---|
| `{title}` | Sunset over Pescadero |
| `{date}` | The painting's date, like 2026-09 (or just 2026 with no month) |
| `{year}` | The painting's year, like 2026 |
| `{artist}` | The artist |
| `{size}` | 11x14 |
| `{medium}` | Oil |
| `{record}` | The record ID, like JS-014 |
| `{today}` | The day you save, like 2026-09-30 |
| `{original}` | The camera's file name, like DSC_0421 |

The default `{title}_{size}_{year}` gives `sunset-over-pescadero_11x14_2026.jpg` and `sunset-over-pescadero_11x14_2026_web.jpg`.

## Tips for good photos

- Shoot straight on, with the camera centered on the painting. Easel fixes small angles, but less correction means sharper results.
- Use even light from both sides, at about 45°, to avoid glare on the paint.
- Shooting RAW gives you the most detail and truest color.

## What's saved inside each JPG

Easel writes these details into both JPGs, so they show up in Lightroom, Bridge, Finder's Get Info and many websites. None of it is drawn on the picture itself.

- **Title**
- **Artist**, plus a copyright line like "© 2026 Your Name"
- **Date**: when you saved the JPG. The painting's own date (the Date you type) only goes in the description.
- **Description**, like "Sunset over Pescadero by Jane Doe, Oil, 11x14 in (September 2026). Record ID: JS-014"
- **Record ID** (Lightroom and Bridge call this field "Job Identifier")

Anything with no value (no artist, no medium, no record ID) is simply left out. Artist and medium come from what you type for the painting, or your defaults in Settings.
