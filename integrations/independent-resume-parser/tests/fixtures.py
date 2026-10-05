"""Original fictional resume fixtures. Minimal PDF writer, no fixture dependencies."""
import zlib


def pdf(pages, *, compressed=False):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    kids = []
    for rows in pages:
        page_id = len(objects) + 1
        kids.append(f'{page_id} 0 R')
        commands = []
        for x, y, text in rows:
            escaped = text.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
            commands.append(f'BT /F1 11 Tf 1 0 0 1 {x} {792-y} Tm ({escaped}) Tj ET')
        stream = '\n'.join(commands).encode('cp1252')
        if compressed:
            stream = zlib.compress(stream)
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id+1} 0 R >>'.encode())
        objects.append(f'<< /Length {len(stream)} '.encode() +
                       (b'/Filter /FlateDecode ' if compressed else b'') + b'>>\nstream\n' + stream + b'\nendstream')
    objects[1] = f'<< /Type /Pages /Count {len(pages)} /Kids [{" ".join(kids)}] >>'.encode()
    content, offsets = b'%PDF-1.7\n', [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(content))
        content += f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(content)
    content += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    content += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    return content + f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()


SINGLE = [(45, 45, 'Avery Example'), (45, 65, 'avery@example.invalid | +1 202-555-0142'),
          (45, 85, 'https://example.invalid/avery'), (45, 125, 'Education'),
          (45, 145, 'Fictional University | BSc Computing | 2018 - 2022'),
          (45, 185, 'Experience'), (45, 205, 'Sample Labs | Software Engineer | 2022 - Present'),
          (45, 225, 'Built a local scheduling tool; improved test coverage.'),
          (45, 265, 'Projects'), (45, 285, 'Orbit Notes - offline note organizer'),
          (45, 325, 'Skills'), (45, 345, 'Python, SQL, TypeScript'),
          (45, 385, 'Interests'), (45, 405, 'Community astronomy and ceramics.')]

TWO_COLUMN = [(45, 45, 'Avery Example'), (45, 90, 'Skills'),
              (45, 110, 'Python, SQL'), (45, 130, 'TypeScript, Git'),
              (45, 180, 'Education'), (45, 200, 'Fictional College'),
              (45, 220, 'BSc Computing 2022'), (335, 90, 'Experience'),
              (335, 110, 'Sample Labs - Engineer'), (335, 130, '2022 - Present'),
              (335, 150, 'Built a scheduling tool.'), (335, 190, 'Projects'),
              (335, 210, 'Orbit Notes'), (335, 230, 'Offline note organizer.')]
