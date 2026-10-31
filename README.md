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
| [`2-progress-bar.lua`](#2-progress-barlua) | Progress bar styles for the status bar while reading |
| [`2-reading-session.lua`](#2-reading-sessionlua) | Session summary, daily goal with streak, and a recap when coming back to a book |

---

### `2-cover-grid.lua`

Makes the bookshelf uniform: every cover has the same aspect ratio, including the thumbnails
that represent folders, and reading information shows up as small badges.

![Folders: before and after](docs/cover-grid-folders.png)

![Books: before and after](docs/cover-grid-books.png)

- **One aspect ratio (2:3)** for books, folder thumbnails and the generated covers of books
  without an image. Very wide covers are centered on a gray background instead of distorted.
- **Rounded corners** drawn by the patch itself, no extra icon files needed.
- **Reading badges** you can mix and match, with four presets to start from.

Everything is set in *Project: Title settings → Cover badges*:

| Option | Choices |
|---|---|
| Apply a preset | Classic, Medals, Quest, Rings |
| Progress | badge (with a flame), XP bar, XP bar and badge, ring, hidden — see below |
| Finished / on hold | medal (trophy), award, stamp, ribbon, banner, check, dog-ear, hidden — see below |
| Badge size | small, medium, large |
| Icons inside badges | flame, hourglass and book icons on or off |
| Series number | `#2` on the top left |
| Page count on new books | page count on books not opened yet |
| Collection star | star on books that are in a collection |
| Fade finished covers | lightens the covers of finished books |
| Idle after | days without opening a book in progress before its progress turns into an hourglass (gray bar or ring); 0 turns it off |

**Progress** on books you are reading. Every option also shows when a book was not opened
for longer than *Idle after*:

![Progress options](docs/cover-grid-progress.png)

**Finished / on hold** marks:

![Finished and on hold marks](docs/cover-grid-status.png)

The idle mark is only visual: the book status stays *Reading*. Defaults for every option, plus
aspect ratio and corner radius, live in the `CONFIG` table at the top of the file.

Requires Project: Title in *Cover Grid* mode. Icons from [Tabler Icons](https://tabler.io/icons) (MIT).

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

### `2-progress-bar.lua`

New looks for the status bar progress bar while reading, chosen in
*Status bar → Progress bar → Style*:

![Progress bar styles](docs/progress-bar-styles.png)

- **Rounded:** one rounded bar with a small gap where each chapter starts.
- **Segments:** one block per chapter, like quest stages — chapters already read are filled
  and the current one fills up as you read.
- **Dual (session and book):** the thin line marks the stretch read in this session, from the
  page where you opened the book to the current one; the bar below shows the whole book.
- **KOReader default** keeps the original bar.

Chapters come from the first level of the table of contents. A taller bar (*Thickness, height
& colors*) suits the dual style.

---

### `2-reading-session.lua`

Makes each reading session count, in three parts that can be turned on or off:

![Session summary and recap](docs/reading-session.png)

- **Session summary:** when you close a book, a message shows the time read, the pages read,
  how the percentage moved and how many chapters you finished.
- **Daily goal and streak:** a goal in pages or minutes per day. The summary shows today's
  total against the goal and how many days in a row you reached it. Totals come from the
  *Reading statistics* plugin, so they add up every book read that day.
- **Where was I?:** when you open a book you haven't opened for a number of days (7 by
  default), a recap shows how long it has been, the current chapter with the pages left in it,
  and your last highlights and notes in that book.

Settings are in *Menu → Tools → Reading session*, while reading. The goal and the streak need
the *Reading statistics* plugin enabled; the summary and the recap work without it.

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
- **Paweł Kuna** — [Tabler Icons](https://github.com/tabler/tabler-icons) (MIT): trophy, pause,
  flame, hourglass and book shapes used by `2-cover-grid.lua`.
- **dmalinovsky** — `2-logical-page-count.lua` gist: synthetic pages by character count.
  Starting point for `2-physical-pages.lua`.
- **Kaya** — Statistics plugin fork with `applyPerfectSync`, which matched page numbers to a
  physical page count. `2-physical-pages.lua` reads the values it saved.
- A highlight color theme shared on Reddit and a highlight filter patch, both by unknown
  authors. Basis for `2-highlights.lua`.

## License

[AGPL-3.0](LICENSE), the same as KOReader.
