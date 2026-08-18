import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { ContractBundleSchema, MetricsSchema, MonitorConfigSchema } from '../src/types'

const fixturePath = process.env.MONITOR_CONTRACT_FIXTURE ?? '.contract/haskell.json'
const fixture: unknown = JSON.parse(readFileSync(fixturePath, 'utf8'))

describe('Haskell -> JSON -> TypeScript contract', () => {
  it('accepts every REST and WebSocket payload emitted by the current Haskell ADTs', () => {
    expect(() => ContractBundleSchema.parse(fixture)).not.toThrow()
  })

  it('rejects a renamed metrics field instead of producing undefined', () => {
    const bundle = ContractBundleSchema.parse(fixture)
    const metrics = bundle.servers[0]?.metrics
    expect(metrics).not.toBeNull()
    if (!metrics) return

    const { cpu: renamedValue, ...withoutCpu } = metrics
    const renamed = { ...withoutCpu, cpuUsage: renamedValue }
    expect(MetricsSchema.safeParse(renamed).success).toBe(false)
  })

  it('proves the editable configuration boundary and rejects renamed fields', () => {
    const bundle = ContractBundleSchema.parse(fixture)
    const { sshHost: renamedValue, ...withoutSshHost } = bundle.config.servers[0]!
    const renamed = {
      ...bundle.config,
      servers: [{ ...withoutSshHost, host: renamedValue }],
    }
    expect(MonitorConfigSchema.safeParse(renamed).success).toBe(false)
  })
})
