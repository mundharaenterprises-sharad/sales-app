import { registerSW } from 'virtual:pwa-register'

/**
 * Keeping every phone on the current build.
 *
 * A service worker makes the app open instantly and work with no signal, and
 * it does that by serving the copy it already has. The cost is that a new
 * build is not the build you are looking at: the worker fetches it quietly in
 * the background and the page carries on running the code it started with.
 * Open the app again and you get the version from last time; the one after
 * that is the new one. On a phone where the app is never really closed, that
 * second opening can be days away.
 *
 * Which is indistinguishable, from the outside, from the change never having
 * been made. That is the whole of it: work that was finished, committed,
 * built and served looked missing because the phone was holding an older copy
 * and nothing on the screen said so.
 *
 * So three things happen here.
 *
 * The app asks whether there is a newer build — on opening, every ten minutes
 * while it is open, whenever it is brought back to the front, and when the
 * connection comes back. The default asks once, at registration, and never
 * again.
 *
 * When there is one, it loads it the moment nobody is looking: the next time
 * the app goes into the background. A reload is instant and invisible there,
 * and they come back to the new build. It deliberately does not reload a page
 * somebody is using — a rep three lines into an order would lose them, and
 * losing an order to deliver a change is a bad trade.
 *
 * And it says so. The Home screen carries the build date, so "am I on the
 * latest?" is a question with an answer on the screen, and offers to load a
 * waiting build straight away for anyone who does not want to wait.
 */

type Listener = (waiting: boolean) => void

/** Ten minutes: often enough that a morning's deploy reaches the field before lunch. */
const CHECK_EVERY = 10 * 60 * 1000

let waiting = false
let apply: ((reload?: boolean) => Promise<void>) | null = null
let registration: ServiceWorkerRegistration | undefined
const listeners = new Set<Listener>()

function announce() {
  for (const l of listeners) l(waiting)
}

/** Subscribe to "a newer build is sitting ready". Returns an unsubscribe. */
export function onUpdateWaiting(listener: Listener): () => void {
  listeners.add(listener)
  listener(waiting)
  return () => {
    listeners.delete(listener)
  }
}

/** Load the waiting build now, discarding whatever is on screen. */
export function applyUpdate() {
  if (apply) void apply(true)
  else window.location.reload()
}

/** Ask the server whether a newer build has been published. */
export function checkForUpdate() {
  void registration?.update()
}

/** Whether a newer build is ready, without subscribing. */
export function updateIsWaiting() {
  return waiting
}

/** Called once, from main.tsx, before the app renders. */
export function startUpdateWatch() {
  apply = registerSW({
    immediate: true,

    onNeedRefresh() {
      waiting = true
      announce()
      // Nobody is looking at a hidden page, so there is nothing to interrupt.
      if (document.visibilityState === 'hidden') applyUpdate()
    },

    onRegisteredSW(_swUrl, r) {
      registration = r
      if (!r) return
      setInterval(() => {
        void r.update()
      }, CHECK_EVERY)
    },
  })

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') checkForUpdate()
    else if (waiting) applyUpdate()
  })

  window.addEventListener('online', checkForUpdate)
}

/** When this build was made. */
export const BUILD_TIME = __BUILD_TIME__

/** "26 Sep 2026, 14:20" in the reader's own time. */
export function buildLabel(): string {
  const d = new Date(BUILD_TIME)
  if (Number.isNaN(d.getTime())) return 'development build'
  return d.toLocaleString(undefined, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}
