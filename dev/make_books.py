# Builds minimal EPUBs with covers of varied aspect ratios to test the cover grid
import zipfile, io, sys, os
from PIL import Image, ImageDraw
out = sys.argv[1]
books = [
  ("Dune", "Frank Herbert", (600, 900), 40, "Dune", 1),
  ("Dune Messiah", "Frank Herbert", (600, 960), 80, "Dune", 2),
  ("Children of Dune", "Frank Herbert", (600, 900), 120, "Dune", 3),
  ("Neuromancer", "William Gibson", (600, 800), 160, None, None),
  ("Foundation", "Isaac Asimov", (600, 1000), 200, None, None),
  ("Wide Book", "Test Author", (800, 600), 90, None, None),
  ("Square Book", "Test Author", (700, 700), 140, None, None),
  ("No Cover", "Test Author", None, 0, None, None),
]
for title, author, size, gray, series, idx in books:
    fn = os.path.join(out, title.replace(" ", "_") + ".epub")
    z = zipfile.ZipFile(fn, "w")
    z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    cover_meta, cover_item = "", ""
    if size:
        im = Image.new("L", size, gray); d = ImageDraw.Draw(im)
        d.rectangle([10, 10, size[0]-10, size[1]-10], outline=255 if gray < 128 else 0, width=8)
        d.text((40, 60), title, fill=255 if gray < 128 else 0)
        b = io.BytesIO(); im.save(b, "JPEG"); z.writestr("OEBPS/cover.jpg", b.getvalue())
        cover_meta = '<meta name="cover" content="cover-img"/>'
        cover_item = '<item id="cover-img" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>'
    ser = f'<meta name="calibre:series" content="{series}"/><meta name="calibre:series_index" content="{idx}"/>' if series else ""
    chapters = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(5))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(5))
    z.writestr("OEBPS/content.opf", f'''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">{title}</dc:identifier><dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language>{cover_meta}{ser}</metadata><manifest>{cover_item}{chapters}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine>{spine}</spine></package>''')
    z.writestr("OEBPS/nav.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>' + "".join(f'<li><a href="c{i}.xhtml">Chapter {i+1}</a></li>' for i in range(5)) + '</ol></nav></body></html>')
    for i in range(5):
        z.writestr(f"OEBPS/c{i}.xhtml", f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter {i+1}</h1>' + "<p>Lorem ipsum dolor sit amet. </p>" * 300 + "</body></html>")
    z.close()
print("ok", len(books))
