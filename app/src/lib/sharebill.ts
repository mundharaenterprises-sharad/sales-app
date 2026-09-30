import { toBlob } from 'html-to-image'

/**
 * Sending a bill to the shopkeeper.
 *
 * It goes as a picture, not a PDF, for two reasons. A picture previews inside
 * the WhatsApp conversation, where a PDF is an attachment somebody has to
 * decide to open — and it is what shopkeepers are used to receiving. And
 * making a real PDF in the browser costs roughly three times the download of
 * making a picture, on an app already too heavy on a phone.
 *
 * The bill is drawn from the same markup that prints, so what the customer
 * receives and what goes in the file are the same document. No second
 * template to keep in step, which is the usual way a shared copy ends up
 * disagreeing with the printed one.
 *
 * Three things can happen, and all three are ordinary:
 *
 *   The phone can share files — the share sheet opens and WhatsApp is in it.
 *   The phone can share, but not files — the text goes with a note that the
 *     picture was saved, and the picture downloads.
 *   The browser cannot share at all, as most desktops cannot — the picture
 *     downloads and the caller says so.
 *
 * The caller is told which happened, because "nothing appeared to happen" is
 * the worst of the three and is exactly what a silent download looks like on
 * a desktop.
 */

export type ShareOutcome = 'shared' | 'downloaded' | 'cancelled'

/** Can this browser put a file into a share sheet? */
export function canShareFiles(): boolean {
  if (typeof navigator === 'undefined' || !navigator.canShare || !navigator.share) return false
  try {
    // A probe file, because canShare() answers about the actual payload type.
    const probe = new File([new Blob([''], { type: 'image/png' })], 'p.png', { type: 'image/png' })
    return navigator.canShare({ files: [probe] })
  } catch {
    return false
  }
}

function save(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

/**
 * Draw an element to a PNG and hand it to the phone.
 *
 * `node` is the printed bill sheet itself. It is drawn at three times its size
 * because a bill is small type on a small sheet, and a screenshot of it at
 * actual size is unreadable on the phone it arrives on.
 *
 * Before the drawing, the sheet is given the `bill-image` class, which swaps
 * the screen's palette for the printed one — black ink, larger type, and
 * colours written out rather than taken from variables so that a phone in
 * dark mode does not send a bill in white-on-white. The class comes off again
 * in a `finally`, because leaving it on would change the page the person is
 * still looking at.
 */
export async function shareElementAsImage(
  node: HTMLElement,
  { filename, title, text }: { filename: string; title: string; text: string },
): Promise<ShareOutcome> {
  // Only the drawing is done with the class on. Sharing can sit open for as
  // long as somebody takes to choose a contact, and the bill behind the share
  // sheet should look like the app, not like the picture.
  let blob: Blob
  node.classList.add('bill-image')
  try {
    blob = await draw(node)
  } finally {
    node.classList.remove('bill-image')
  }

  const file = new File([blob], filename, { type: 'image/png' })

  if (canShareFiles()) {
    try {
      await navigator.share({ files: [file], title, text })
      return 'shared'
    } catch (e) {
      // The share sheet was dismissed. Not an error, and emphatically not a
      // reason to download something they did not ask for.
      if (e instanceof DOMException && e.name === 'AbortError') return 'cancelled'
      // Anything else — a phone that said it could share and then could not —
      // still ends with the bill in their hands.
    }
  }

  save(blob, filename)
  return 'downloaded'
}

async function draw(node: HTMLElement): Promise<Blob> {
  // The class above changes type sizes, so the sheet is a different height
  // than it was a moment ago. Measuring before the browser has laid it out
  // again crops the bottom off the bill — which is exactly what it did.
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))

  // The size has to be stated. Left to work it out, the drawing came out
  // shifted and cropped — the sheet is centred with an automatic margin and
  // capped at A5 width, and neither of those survives being lifted out of the
  // page. Measuring it first and cancelling the margin puts the bill back at
  // the top left of its own picture, which is where a bill goes.
  const rect = node.getBoundingClientRect()

  const blob = await toBlob(node, {
    // Three, not two. A bill is small type, and the reader is a shopkeeper
    // holding a phone, often outdoors.
    pixelRatio: 3,
    width: Math.ceil(rect.width),
    height: Math.ceil(rect.height),
    // The sheet has no background of its own on screen; without this the
    // transparent areas come out black in some chat apps.
    backgroundColor: '#ffffff',
    style: {
      margin: '0',
      // On screen the sheet is a card. On a shopkeeper's phone it should be a
      // bill, so the card goes.
      boxShadow: 'none',
      borderRadius: '0',
      border: 'none',
      transform: 'none',
    },
    // Drawing has to inline every style, and an unreachable font or image
    // would otherwise reject the whole thing. Skip what cannot be fetched
    // rather than fail to send the bill over a decoration.
    skipFonts: true,
  })
  if (!blob) throw new Error('The bill could not be turned into a picture.')
  return blob
}
