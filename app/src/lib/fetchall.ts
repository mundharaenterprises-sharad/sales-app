/**
 * Every row, not the first thousand.
 *
 * PostgREST caps how many rows one request will return. Ask for more and it
 * quietly hands back the cap, with no error and nothing in the response that
 * looks wrong — you get rows, they are real rows, there are simply fewer of
 * them than exist. A report built on that does not fail; it under-reports, and
 * the figure goes out looking exactly like a correct one.
 *
 * That is what went wrong with the sales register's product breakdown. The
 * bills fit under the cap and arrived complete; the LINES — one row per bill
 * line, several times as many — did not, so the Products and By salesman
 * sheets were built from whatever slice came back. With no ordering on the
 * query, which slice that was was up to the planner, which is why the tabs
 * were sometimes missing and never obviously wrong.
 *
 * So this pages. It asks for an exact count alongside the first page, keeps
 * fetching ranges until it has that many rows, and **refuses rather than
 * returning a partial answer**: a caller that gets rows back can treat them as
 * all the rows. Half a product total is worse than none, because only one of
 * the two is obviously wrong.
 *
 * The caller builds the query — `.select('*', { count: 'exact' })`, its
 * filters, **and its ordering** — and hands over a function that produces a
 * fresh one each time, because a builder cannot be reused once awaited.
 *
 * The ordering is not optional. Paging an unordered query is meaningless: the
 * same row can arrive on two pages and another on none. Only the caller knows
 * what order its rows belong in, so only the caller can supply it.
 */

interface Pageable<T> {
  range(from: number, to: number): PromiseLike<{
    data: T[] | null
    error: { message: string } | null
    count: number | null
  }>
}

export async function fetchAll<T>(
  build: () => Pageable<T>,
  /** Rows per request. Comfortably under any cap worth worrying about. */
  page = 1000,
): Promise<{ data: T[]; error: string | null }> {
  const out: T[] = []
  let total: number | null = null
  let start = 0

  for (;;) {
    const { data, error, count } = await build().range(start, start + page - 1)
    if (error) return { data: [], error: error.message }

    if (total === null && typeof count === 'number') total = count

    const got = data ?? []
    out.push(...got)

    // Advance by what actually arrived, not by what was asked for. The server
    // may cap a page BELOW the size requested — that is the whole reason this
    // function exists — so a short page is not evidence that the data has run
    // out. Treating it as such was the first version of this, and it stopped
    // after one page every time, which the test caught.
    if (got.length === 0) break
    start += got.length

    if (total === null) {
      // No count came back, so a short page is the only end-of-data signal
      // there is.
      if (got.length < page) break
    } else if (out.length >= total) {
      break
    }
  }

  if (total !== null && out.length < total) {
    return { data: [], error: `only ${out.length} of ${total} rows could be read` }
  }
  return { data: out, error: null }
}
