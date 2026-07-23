import { describe, it, expect } from 'bun:test'
import { selectDelivery } from '../src/irc-server'

describe('inbound delivery mode', () => {
  it('defaults to notification when ROOST_DELIVERY is unset', () => {
    expect(selectDelivery(undefined)).toBe('notification')
    expect(selectDelivery('')).toBe('notification')
  })
  it('selects tmux when ROOST_DELIVERY=tmux', () => {
    expect(selectDelivery('tmux')).toBe('tmux')
  })
  it('falls back to notification for an unknown value', () => {
    expect(selectDelivery('bogus')).toBe('notification')
  })
})
