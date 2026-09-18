import type { ReactNode } from 'react'

export function Spinner() {
  return <span className="spinner" aria-hidden="true" />
}

export function Loading({ what = 'Loading' }: { what?: string }) {
  return (
    <div className="loading-row" role="status">
      <Spinner />
      <span>{what}…</span>
    </div>
  )
}

export function Empty({
  title,
  children,
}: {
  title: string
  children?: ReactNode
}) {
  return (
    <div className="empty">
      <h3>{title}</h3>
      {children && <p>{children}</p>}
    </div>
  )
}

export function Banner({
  tone = 'info',
  children,
}: {
  tone?: 'info' | 'warn' | 'bad'
  children: ReactNode
}) {
  return (
    <div className={`banner ${tone}`} role={tone === 'bad' ? 'alert' : 'status'}>
      <div>{children}</div>
    </div>
  )
}

export function ErrorBanner({ error }: { error: string | null }) {
  if (!error) return null
  return <Banner tone="bad">{error}</Banner>
}
