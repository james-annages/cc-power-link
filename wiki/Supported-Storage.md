# Supported storage

| Storage | Peripheral | What you get |
|---|---|---|
| Mekanism induction matrix | `inductionPort`, `reinforcedInductionPort` | live input/output, cells, providers, size |
| Draconic Evolution energy core | `draconic_rf_storage` | level, live input/output; capacity read from the core |
| Anything else with `getEnergy`/`getEnergyCapacity` or `getEnergyStored`/`getMaxEnergyStored` | any | level and time to full/empty; rates are measured from the change in energy |

Auto-detect prefers a matrix, then an energy core, then the largest generic storage. It re-checks every 10 seconds, so
a better storage attached later is picked up. Set `StorageInterface` to pin one.

## Energy cores

The capacity is read from the core, nothing is hardcoded. The tier is only a label: set `StorageTier` to 1-8 to show
"Tier N" on the panel, or leave it 0 to show none.

## Measured rates

Generic storage reports no input/output, so the sender measures the change in stored energy between reads. On a
laggy server (TPS below 20) the figure is approximate.
