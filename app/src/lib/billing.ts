import { supabase } from './supabase'

/**
 * Turning order lines into bill lines.
 *
 * Shared by the single-bill screen and the bulk "bill these orders" action so
 * that both produce exactly the same thing: a bill raised in bulk must be the
 * same bill you would have got clicking through the order by hand.
 */

export interface OrderLineRow {
  id: string
  product_id: string
  uom: 'BASE' | 'PACK'
  qty: number
  pack_size: number
  rate: number
  line_discount_pct: number | null
  qty_pending_base: number
  product: {
    code: string
    name: string
    base_uom: string
    pack_uom: string | null
    pack_size: number
  }
}

export interface BillLine {
  order_line_id: string
  product_id: string
  uom: 'BASE' | 'PACK'
  qty: number
  rate: number
  /**
   * What the rep agreed at the shop, as a percentage.
   *
   * A percentage rather than an amount because a bill often covers only part
   * of an order — half today, the rest when stock arrives — and "200 off"
   * cannot be split honestly across two bills, while "5%" can.
   */
  line_discount_pct: number | null
}

/**
 * What is still pending, in the unit the rep ordered in — but only while it
 * still divides into whole packs. Half a box goes out as pieces, with the rate
 * scaled down to match, because a line saying "0.5 BOX" is a rounding error
 * waiting to happen.
 */
export function pendingAsLine(r: OrderLineRow): BillLine | null {
  const pending = Number(r.qty_pending_base)
  if (!(pending > 0)) return null

  const packSize = Number(r.pack_size)
  const asPack = r.uom === 'PACK' && packSize > 1 && pending % packSize === 0

  return {
    order_line_id: r.id,
    product_id: r.product_id,
    uom: asPack ? 'PACK' : 'BASE',
    qty: asPack ? pending / packSize : pending,
    rate: asPack
      ? Number(r.rate)
      : Number(r.rate) / (r.uom === 'PACK' && packSize > 1 ? packSize : 1),
    line_discount_pct: r.line_discount_pct == null ? null : Number(r.line_discount_pct),
  }
}

const LINE_SELECT =
  'id, product_id, uom, qty, pack_size, rate, line_discount_pct, qty_pending_base,' +
  ' product:product_id (code, name, base_uom, pack_uom, pack_size)'

export async function fetchOrderLines(orderId: string): Promise<OrderLineRow[]> {
  const { data, error } = await supabase
    .from('sales_order_line')
    .select(LINE_SELECT)
    .eq('order_id', orderId)
    .order('line_no')

  if (error) throw error
  return (data ?? []) as unknown as OrderLineRow[]
}
