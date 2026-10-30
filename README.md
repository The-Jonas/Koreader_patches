# Koreader_patches

User patches for [KOReader](https://github.com/koreader/koreader), built for e-ink reading
with the [Project: Title](https://github.com/joshuacant/ProjectTitle) plugin.

> Tested with **KOReader v2026.07** and **Project: Title v3.8.3** on a Kindle Paperwhite (11th gen).

## Installation

1. Connect your e-reader to a computer and open the `koreader/` folder.
2. Create a `patches/` folder if it doesn't exist.
3. Copy the `.lua` files you want from this repository's [`patches/`](patches) folder.
4. Restart KOReader. Patches are listed under *Settings → Patch management*, where they can
   also be turned off.

Every file starts with a comment block explaining its goal, what it does and how to use it.
Patches with options have a configuration table right below that block.

## Patches

| Patch | Summary |
|---|---|
| [`2-cover-grid.lua`](#2-cover-gridlua) | Uniform covers and reading badges in the Project: Title grid |
| [`2-physical-pages.lua`](#2-physical-pageslua) | Page numbers that match the printed edition |
| [`2-highlights.lua`](#2-highlightslua) | Highlight categories readable in grayscale, plus filter shortcuts |
| [`2-reading-dates.lua`](#2-reading-dateslua) | Start and finish date of every book |

---

### `2-cover-grid.lua`

Makes the bookshelf uniform: every cover has the same aspect ratio, including the thumbnails
that represent folders, and reading information shows up as small badges.

![Folders: before and after](docs/cover-grid-folders.png)

![Books: before and after](docs/cover-grid-books.png)

- **One aspect ratio (2:3)** for books, folder thumbnails and the generated covers of books
  without an image. Very wide covers are centered on a gray background instead of distorted.
- **Rounded corners** drawn by the patch itself, no extra icon files needed.
- **Badges**, each in its own corner:

  | Corner | Badge |
  |---|---|
  | top left | series number (`#2`) and, below it, a star if the book is in a collection |
  | top right | percentage read |
  | bottom left | page count, for books not opened yet |
  | bottom right | dog-ear: black for finished, white for abandoned |

- Option to fade the covers of finished books.

Requires Project: Title in *Cover Grid* mode. Everything can be tuned in the `CONFIG` table.

---

### `2-physical-pages.lua`

Makes page 120 on the reader be page 120 of the physical book. The patch tunes KOReader's
*stable page numbers*, working out how many characters fit on each page so that the total
matches the printed edition.

The page count comes from one of two sources, per book:

- **Automatic:** [Open Library](https://openlibrary.org) lookup by the EPUB's ISBN or, without
  an ISBN, by title and author (needs Wi-Fi).
- **Manual:** you type the page count of your edition.

Found under *Menu → navigation tab → Settings → Stable page numbers → Printed edition pages*,
with an EPUB open. The value is saved and applied again every time the book is opened. Books
that already ship the publisher's page numbers are left untouched unless you set a value
manually.

---

### `2-highlights.lua`

Turns the highlight colors into reading categories and makes sure each one lands on a
different gray level on a grayscale e-ink screen (16 levels). Each color keeps its hue, so it
stays recognizable on color screens and in exports.

![Highlight categories in color and in grayscale](docs/highlights.png)

It also adds three gesture actions (*Settings → Taps and gestures → Gesture manager*): filter
highlights by category, by style, or by both. Each one opens the highlight list with the
filter picker already shown.

Names, symbols and tones live in the `CATEGORIES` table.

---

### `2-reading-dates.lua`

Records when each book was started and finished, automatically:

- **Started:** the date the book was first opened.
- **Finished:** the date the book was marked as finished, no matter how.

The dates show up in *Book information* and are saved in the book metadata
(`started_on` and `finished_on`). To undo an accidental opening, use *Reset* in the file
manager.

---

## Development

The [`dev/`](dev) folder holds what is used to test the patches in a KOReader emulator
(the Linux build of KOReader running at the Paperwhite 11 resolution):

- `make_books.py` builds test EPUBs with covers of varied aspect ratios and a series.
- `shot.sh` opens the emulator on a folder or book and saves a screenshot.

## Credits

These patches were rewritten from community ideas:

- **SeriousHornet** — [KOReader.patches](https://github.com/SeriousHornet/KOReader.patches):
  rounded and stretched covers, page, percentage, series, collection and status badges.
  Basis for `2-cover-grid.lua`.
- **dmalinovsky** — `2-logical-page-count.lua` gist: synthetic pages by character count.
  Starting point for `2-physical-pages.lua`.
- **Kaya** — Statistics plugin fork with `applyPerfectSync`, which matched page numbers to a
  physical page count. `2-physical-pages.lua` reads the values it saved.
- A highlight color theme shared on Reddit and a highlight filter patch, both by unknown
  authors. Basis for `2-highlights.lua`.

## License

[AGPL-3.0](LICENSE), the same as KOReader.
