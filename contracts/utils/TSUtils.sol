// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

library TSUtils {
  enum State {
    NONE,
    INVALID,
    MATURED,
    VALID,
    NOT_READY
  }

  uint32 public constant INTERVAL = 7 days;

  /// @notice calculates how many seconds are left to a certain date.
  /// @param timestampFrom to calculate the difference in seconds from a date.
  /// @param timestampTo to calculate the difference in seconds to a date.
  /// @return seconds left to the date.
  function secondsPre(uint256 timestampFrom, uint256 timestampTo) internal pure returns (uint256) {
    return timestampFrom < timestampTo ? timestampTo - timestampFrom : 0;
  }

  /// @notice returns a pool `time` state based on the current time, maxPools available, and INTERVAL.
  /// @param timestamp timestamp of the current time.
  /// @param maturity used as maturity date / pool id.
  /// @param maxPools number of pools available in the time horizon.
  /// @return state: if a pool is VALID, not yet available(NOT_READY), INVALID or MATURED.
  function getPoolState(
    uint256 timestamp,
    uint256 maturity,
    uint8 maxPools
  ) private pure returns (State) {
    if (maturity % INTERVAL != 0) return State.INVALID;

    if (maturity < timestamp) return State.MATURED;

    if (maturity > timestamp - (timestamp % INTERVAL) + (INTERVAL * maxPools)) return State.NOT_READY;

    return State.VALID;
  }

  /// @notice verifies that a maturity is VALID, MATURED, NOT_READY or INVALID.
  /// @dev if expected state doesn't match the calculated one, it reverts with a custom error "UnmatchedPoolState".
  /// @param maturity timestamp of the maturity date to be verified.
  /// @param requiredState state required by the caller to be verified (see TSUtils.State() for description).
  /// @param alternativeState state required by the caller to be verified (see TSUtils.State() for description).
  function validateRequiredPoolState(
    uint8 maxFuturePools,
    uint256 maturity,
    State requiredState,
    State alternativeState
  ) internal view {
    State poolState = getPoolState(block.timestamp, maturity, maxFuturePools);

    if (poolState != requiredState && poolState != alternativeState) {
      if (alternativeState == State.NONE) revert UnmatchedPoolState(uint8(poolState), uint8(requiredState));

      revert UnmatchedPoolStateMultiple(uint8(poolState), uint8(requiredState), uint8(alternativeState));
    }
  }
}

error UnmatchedPoolState(uint8 state, uint8 requiredState);
error UnmatchedPoolStateMultiple(uint8 state, uint8 requiredState, uint8 alternativeState);
