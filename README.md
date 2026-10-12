# Half-Frame Splitter for Lightroom Classic

A Lightroom Classic plug-in for **half-frame 35mm cameras** (Olympus Pen, Pentax 17,
Kodak Ektar H35, Canon Demi, ...). Your scans show two pictures side by side, with a
black line between them. The plug-in finds that black line by itself and gives you each
picture as its own photo.

- **The original is never changed or deleted.** Each pair gets two *virtual copies*,
  named "Half 1" and "Half 2", stacked with the original.
- **No quality loss.** A virtual copy is just a crop instruction in your catalog. No
  pixels are copied or re-encoded. Lightroom always renders from your original file, at
  full quality, and you can still edit or re-crop each half freely.
- **Nothing to import.** The halves appear in Lightroom right away, next to the original.
- **Works offline.** Everything runs on your Mac. Nothing goes to the cloud, and you
  don't need to install Python or any other software. The plug-in uses only Lightroom
  and `sips`, a tool built into every Mac.
- Works with JPEG and TIFF scans: lab scans and your own scanner, 8 or 16 bit, colour
  or B&W.

## Install (about 1 minute)

1. Download this repository: the green **Code** button → **Download ZIP**, then
   double-click the ZIP to unpack it.
2. In Finder choose **Go → Go to Folder...** (Shift-Cmd-G), paste this and press Return:

   ```
   ~/Library/Application Support/Adobe/Lightroom/Modules
   ```

   If the folder does not exist yet, go to `~/Library/Application Support/Adobe/Lightroom`
   and create a folder called `Modules` there.
3. Drag **`HalfFrameSplitter.lrplugin`** from the unpacked download into that `Modules`
   folder.
4. Restart Lightroom Classic.

That's it. Lightroom loads everything in the `Modules` folder automatically. Lightroom
updates leave that folder alone, so the plug-in keeps working after you update
Lightroom.

*Alternative:* in Terminal, run `bash ` followed by a space, drag the file
`scripts/install.sh` from the download into the Terminal window, and press Return. It
does the same copy for you.

## Use

1. In the Library, select your pair scans. A whole roll at once is fine.
2. Choose **Library → Plug-in Extras → Split Half-Frame Pairs...**
   In the Develop module, use **File → Plug-in Extras → Split Half-Frame Pairs...**
3. Click **Split**.

When it's done, each scan has two new virtual copies stacked with it: **Half 1** (the
left, or top, picture as shown on screen) and **Half 2**. A summary tells you what
happened.

### When the line is unclear

Sometimes the plug-in can't see where to cut. This happens with very dark night frames
(on film, the black line and black shadows look the same), frames that touch or
overlap, or a blank frame. By default it **asks you**. After checking all the other
scans, it shows each unclear one in a window:

- a preview of the scan, turned the way Lightroom shows it, with a **red line** where
  it would cut. The line starts at its best guess, or in the middle if it has none.
- a **slider** to move the line. The preview redraws as you drag.
- **Middle** and **My best guess** buttons.
- **Don't cut it**, which puts the original in the collection
  **Half-Frame Splitter → Needs review**.
- for big batches, a tick box to stop asking and cut the rest at the best guess.
  Those go into "Needs review" so you can check them.

**Cancel all** stops the whole run without changing anything.

If you'd rather not be asked, choose one of the other options in the main window:

- **Split at the best guess (or the middle) and add to "Needs review".**
- **Do not split; only add the original to "Needs review".**

To fine-tune any cut later, select the half, press **R** (the Crop tool) and drag the
edge, like any other crop.

### Options

- **Extra trim at the cut** (default 0.3%) removes a little more on each side of the
  line, so no thin dark edge is left. Increase it if you still see a sliver of black.
- **Also crop away black borders around the pair** (off by default, experimental).
  Useful for your own scanner TIFFs that show black film edges around the pictures.

The plug-in remembers your choices.

### Running it twice

Photos that already have "Half 1"/"Half 2" copies are skipped. To split a photo
again, delete its two halves first: select them → **Photo → Remove Photo...**. This
only removes the virtual copies and never touches the original.

### Real files instead of virtual copies

You don't need files to keep working in Lightroom. If you want separate image files,
for example to share, select the halves and use **File → Export...**. Use TIFF 16-bit
or JPEG quality 100 for the best quality. Tick **Add to This Catalog** if you want the
exported files in Lightroom too.

## Updating

Download the new version and replace `HalfFrameSplitter.lrplugin` in the `Modules`
folder (or run `scripts/install.sh` again). Then restart Lightroom. Your settings and
every half already made are kept. The halves are ordinary virtual copies and don't
depend on the plug-in, so they stay even if you remove it.

## Uninstalling

Quit Lightroom, delete `HalfFrameSplitter.lrplugin` from the `Modules` folder, and
start Lightroom again. Your photos, including all halves, stay as they are.

## Troubleshooting

- **The menu item is missing.** Check **File → Plug-in Manager...**. "Half-Frame
  Splitter" should be listed as installed and running. If you earlier added the plug-in
  from another folder with the *Add* button, remove that entry. Two copies of the same
  plug-in conflict.
- **"could not select it in the current view".** The plug-in has to select each
  photo to make its copies. Turn off the Library filter, or expand the stack, and run
  it again.
- **"the file is missing or its drive is not connected".** Connect the drive that holds
  the scans.
- **A log file** called `HalfFrameSplitter.log` is written to `Documents/LrClassicLogs`
  (on older Lightroom versions `Documents/lrClassicLogs`). It lists what was found for
  every photo, so it's the first place to look if a result surprises you.

## How it works

1. `sips` (built into macOS) reads the scan and writes a small temporary preview, 1200
   px on the long side, without changing your file.
2. The plug-in measures, for every column of the preview, how bright its brightest
   pixels are. The strip of unexposed film between two frames is the only place where
   a whole column, top to bottom, is dark. The darkest such band near the middle is the
   dividing line. The plug-in then finds its exact edges and checks that the result
   makes sense: dark enough, the right width, near the centre, with picture on both
   sides, and only one such line. Light leaks over the line, dust, scratches and
   slightly crooked scans are handled.
3. Lightroom creates the two virtual copies and the plug-in sets their crops.

The plug-in itself is plain Lua text files. It has no compiled parts and needs no
installer, so there's nothing for macOS security to block and nothing that a macOS or
Lightroom update can break.

## For developers

```
HalfFrameSplitter.lrplugin/
  Info.lua           plug-in manifest (menu items, SDK version, id)
  HFSMenuSplit.lua   menu command
  HFSMain.lua        Lightroom side: dialog, sips, virtual copies, crops, collection
  HFSDetect.lua      line detection, crop geometry, orientation handling (pure Lua)
  HFSImage.lua       BMP decoding, EXIF/TIFF orientation reading (pure Lua)
  HFSPluginInfo.lua  Plug-in Manager panel
tests/
  run_tests.lua        unit tests on synthetic pair scans (dark, leaks, skew, B&W, ...)
  run_plugin_test.lua  whole plug-in flow against a simulated Lightroom SDK
  lr_mock.lua          the simulated SDK
  fake_sips.py         Pillow stand-in for macOS sips
  gen_fixtures.py      synthetic test images
```

Run all tests (needs `lua5.1` and Python 3 with `numpy` and `Pillow`):

```
tests/run_all.sh
```

Keep `LrToolkitIdentifier` in `Info.lua` unchanged, because Lightroom stores the
plug-in's settings under it. When releasing, bump the version in both `Info.lua` and
`HFSMain.lua`; a test checks that the two match.
