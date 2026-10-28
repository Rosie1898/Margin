from pathlib import Path
from io import BytesIO
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1] / 'test-results' / 'fixtures'
root.mkdir(parents=True, exist_ok=True)
out = root / 'Margin verification.pdf'
c = canvas.Canvas(str(out), pagesize=(612, 792))
c.setTitle('Reading with Margin')
c.setAuthor('Margin Windows verification')
c.setFillColorRGB(.18, .35, .28)
c.setFont('Helvetica-Bold', 28)
c.drawString(56, 714, 'Reading with Margin')
c.setFont('Helvetica', 11)
c.setFillColorRGB(.45, .52, .48)
c.drawString(56, 687, 'LOCAL READING  /  WINDOWS EDITION  /  VERIFICATION DOCUMENT')
c.setStrokeColorRGB(.76,.85,.80)
c.line(56,665,556,665)
c.setFillColorRGB(.16,.24,.21)
c.setFont('Helvetica-Bold', 17)
c.drawString(56,625,'Keep your thoughts beside the source.')
lines = [
 'A good reader gives ideas room to grow. Margin brings your local PDFs,',
 'highlights, notes, and conversations into one quiet workspace.',
 '',
 'Select this passage to add a highlight, leave a comment, or ask a question.',
 'Every annotation stays linked to its original page and position.',
 '',
 'Search for development to verify text search. Development is a process',
 'of discovering useful questions and connecting them with evidence.',
 '',
 'Your original PDF stays unchanged. Notes and recognized text are',
 'stored locally, and reading works without an internet connection.',
 '',
 'The next page checks rotated text. The final page is an image-only scan',
 'that must be recognized using the Windows on-device OCR engine.'
]
c.setFont('Helvetica',12)
for i,line in enumerate(lines): c.drawString(56,589-i*23,line)
c.setFont('Helvetica',10)
c.setFillColorRGB(.45,.52,.48)
c.drawString(56,56,'Margin verification fixture | Original content | Page 1')
c.showPage()
c.setPageRotation(90)
c.setFont('Helvetica-Bold',20)
c.drawString(70,500,'Rotated page verification')
c.setFont('Helvetica',13)
c.drawString(70,465,'Selection, highlights, and search must follow the visible page geometry.')
c.drawString(70,435,'The word development should appear in the search results on this page.')
c.showPage()
c.setPageRotation(0)
image=Image.new('RGB',(1530,1980),'white');draw=ImageDraw.Draw(image)
font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf',46)
bold=ImageFont.truetype('C:/Windows/Fonts/arialbd.ttf',64)
draw.text((140,180),'LOCAL OCR VERIFICATION',font=bold,fill=(40,60,54))
for i,line in enumerate(['This page is an image with no text layer.',
  'Windows recognizes these words on this computer.',
  'Select the recognized text to make a note.',
  'Search for pineapple after recognition completes.',
  'The original PDF is never modified.']):
  draw.text((140,350+i*105),line,font=font,fill=(35,40,38))
image.save(root/'scan.png')
c.drawImage(ImageReader(image),0,0,width=612,height=792)
c.showPage();c.save()
print(out)
