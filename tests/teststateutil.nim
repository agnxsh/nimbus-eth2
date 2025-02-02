# beacon_chain
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  ./mocking/mock_deposits,
  ../beacon_chain/spec/[
    forks, state_transition, state_transition_block]

from ".."/beacon_chain/bloomfilter import constructBloomFilter
from ".."/beacon_chain/spec/state_transition_epoch import
  get_validator_balance_after_epoch, process_epoch


func round_multiple_down(x: Gwei, n: Gwei): Gwei =
  ## Round the input to the previous multiple of "n"
  x - x mod n

proc valid_deposit(state: var ForkyHashedBeaconState) =
  const deposit_amount = MAX_EFFECTIVE_BALANCE.Gwei
  let validator_index = state.data.validators.len
  let deposit = mockUpdateStateForNewDeposit(
                  state.data,
                  uint64 validator_index,
                  deposit_amount,
                  flags = {}
                )

  let pre_val_count = state.data.validators.len
  let pre_balance = if validator_index < pre_val_count:
                      state.data.balances.item(validator_index)
                    else:
                      0.Gwei
  doAssert process_deposit(
    defaultRuntimeConfig, state.data,
    constructBloomFilter(state.data.validators.asSeq)[], deposit, {}).isOk
  doAssert state.data.validators.len == pre_val_count + 1
  doAssert state.data.balances.len == pre_val_count + 1
  doAssert state.data.balances.item(validator_index) == pre_balance + deposit.data.amount
  doAssert state.data.validators.item(validator_index).effective_balance ==
    round_multiple_down(
      min(
        MAX_EFFECTIVE_BALANCE.Gwei,
        state.data.balances.item(validator_index)),
      EFFECTIVE_BALANCE_INCREMENT.Gwei
    )
  state.root = hash_tree_root(state.data)

proc getTestStates*(
    initialState: ForkedHashedBeaconState, consensusFork: ConsensusFork):
    seq[ref ForkedHashedBeaconState] =
  # Randomly generated slot numbers, with a jump to around
  # SLOTS_PER_HISTORICAL_ROOT to force wraparound of those
  # slot-based mod/increment fields.
  const stateEpochs = [
    0, 1,

    # Around minimal wraparound SLOTS_PER_HISTORICAL_ROOT wraparound
    7, 8, 9,

    # Unexceptional cases, with 2 and 3-long runs
    39, 40, 114, 115, 116, 130, 131,

    # Approaching and passing mainnet SLOTS_PER_HISTORICAL_ROOT wraparound
    255, 256, 257]

  var
    tmpState = assignClone(initialState)
    cache = StateCache()
    info = ForkedEpochInfo()
    cfg = defaultRuntimeConfig

  static: doAssert high(ConsensusFork) == ConsensusFork.Electra
  if consensusFork >= ConsensusFork.Altair:
    cfg.ALTAIR_FORK_EPOCH = 1.Epoch
  if consensusFork >= ConsensusFork.Bellatrix:
    cfg.BELLATRIX_FORK_EPOCH = 2.Epoch
  if consensusFork >= ConsensusFork.Capella:
    cfg.CAPELLA_FORK_EPOCH = 3.Epoch
  if consensusFork >= ConsensusFork.Deneb:
    cfg.DENEB_FORK_EPOCH = 4.Epoch
  if consensusFork >= ConsensusFork.Electra:
    cfg.ELECTRA_FORK_EPOCH = 5.Epoch

  for i, epoch in stateEpochs:
    let slot = epoch.Epoch.start_slot
    if getStateField(tmpState[], slot) < slot:
      process_slots(
        cfg, tmpState[], slot, cache, info, {}).expect("no failure")

    if i mod 3 == 0:
      withState(tmpState[]):
        valid_deposit(forkyState)
    doAssert getStateField(tmpState[], slot) == slot

    if tmpState[].kind == consensusFork:
      result.add assignClone(tmpState[])

proc checkPerValidatorBalanceCalc*(
    state: deneb.BeaconState | electra.BeaconState): bool =
  var
    info: altair.EpochInfo
    cache: StateCache
  let tmpState = newClone(state)  # slow, but tolerable for tests
  discard process_epoch(defaultRuntimeConfig, tmpState[], {}, cache, info)
  for i in 0 ..< tmpState.balances.len:
    if tmpState.balances.item(i) != get_validator_balance_after_epoch(
        defaultRuntimeConfig, state, default(UpdateFlags), cache, info,
        i.ValidatorIndex):
      return false

  true
