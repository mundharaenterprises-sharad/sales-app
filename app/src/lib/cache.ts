/**
 * A small IndexedDB store for the data reps need to see without a signal:
 * products, stock levels, parties, routes.
 *
 * Deliberately NOT used for anything that has to be right to the second. Every
 * cached read carries the moment it was fetched, and the screen shows that age
 * prominently, because a rep acting on three-hour-old stock should know it.
 *
 * Orders are never written offline. That is what keeps the reservation
 * trustworthy — see the offline section of the requirements.
 */

const DB_NAME = 'sales-app'
const DB_VERSION = 1
const STORE = 'snapshots'

export interface Snapshot<T> {
  key: string
  fetchedAt: number
  data: T
}

let dbPromise: Promise<IDBDatabase> | null = null

function open(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise

  dbPromise = new Promise((resolve, reject) => {
    // Private windows and blocked site data both throw here.
    let req: IDBOpenDBRequest
    try {
      req = indexedDB.open(DB_NAME, DB_VERSION)
    } catch (e) {
      reject(e)
      return
    }
    req.onupgradeneeded = () => {
      const db = req.result
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: 'key' })
      }
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })

  return dbPromise
}

export async function putSnapshot<T>(key: string, data: T): Promise<void> {
  try {
    const db = await open()
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite')
      tx.objectStore(STORE).put({ key, fetchedAt: Date.now(), data } as Snapshot<T>)
      tx.oncomplete = () => resolve()
      tx.onerror = () => reject(tx.error)
    })
  } catch {
    // Caching is a convenience. Losing it must never break the screen.
  }
}

export async function getSnapshot<T>(key: string): Promise<Snapshot<T> | null> {
  try {
    const db = await open()
    return await new Promise<Snapshot<T> | null>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readonly')
      const req = tx.objectStore(STORE).get(key)
      req.onsuccess = () => resolve((req.result as Snapshot<T>) ?? null)
      req.onerror = () => reject(req.error)
    })
  } catch {
    return null
  }
}

export async function clearSnapshots(): Promise<void> {
  try {
    const db = await open()
    await new Promise<void>((resolve) => {
      const tx = db.transaction(STORE, 'readwrite')
      tx.objectStore(STORE).clear()
      tx.oncomplete = () => resolve()
      tx.onerror = () => resolve()
    })
  } catch {
    /* nothing to clear */
  }
}
