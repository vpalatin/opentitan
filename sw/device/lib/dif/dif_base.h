// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENTITAN_SW_DEVICE_LIB_DIF_DIF_BASE_H_
#define OPENTITAN_SW_DEVICE_LIB_DIF_DIF_BASE_H_

/**
 * @file
 * @brief Shared macros and headers for DIFs.
 */

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

/**
 * The result of a DIF operation.
 *
 * NOTE: additional result values can be defined in the manually-implemented
 * header by creating an additional *_result_t enum type. See the Lifecycle
 * Controller DIF for how this may be implemented.
 */
typedef enum dif_result {
  /**
   * Indicates that the operation succeeded.
   */
  kDifOk = 0,
  /**
   * Indicates some unspecified failure.
   */
  kDifError = 1,
  /**
   * Indicates that some parameter passed into a function failed a
   * precondition.
   *
   * When this value is returned, no hardware operations occurred.
   */
  kDifBadArg = 2,
  /**
   * The operation failed because writes to a required register are
   * disabled.
   */
  kDifLocked = 3,
  /**
   * The operation failed because the IP is processing an operation, and will
   * finish in some amount of time. A function that returns this error may be
   * retried at any time, and is guaranteed to have not produced any side
   * effects.
   */
  kDifUnavailable = 4,
  /**
   * Indicates that the Ip's FIFO (if it has one or more of) is full.
   */
  kDifIpFifoFull = 5,
  /**
   * Indicates that the attempted operation would attempt a read/write to an
   * address that would go out of range.
   */
  kDifOutOfRange = 6,
  /**
   * Indicates that the attempted operation would attempt a read/write to an
   * address that is not aligned.
   */
  kDifUnaligned = 7,
} dif_result_t;

/**
 * A toggle state: enabled, or disabled.
 *
 * This enum may be used instead of a `bool` when describing an enabled/disabled
 * state.
 */
typedef enum dif_toggle {
  /**
   * The "disabled" state.
   */
  kDifToggleDisabled = 0,
  /**
   * The "enabled" state.
   */
  kDifToggleEnabled = 1,
} dif_toggle_t;

/**
 * Checks if a DIF toggle type is valid.
 *
 * @param val A potential dif_toggle_t value.
 * @return Bool indicating validity of toggle value.
 */
inline bool dif_is_valid_toggle(dif_toggle_t val) {
  switch (val) {
    case kDifToggleEnabled:
      return true;
    case kDifToggleDisabled:
      return true;
    default:
      return false;
  }
}

/**
 * Converts a `dif_toggle_t` to a `bool`.
 *
 * @param val A dif_toggle_t value.
 * @return Corresponding bool value.
 */
inline bool dif_toggle_to_bool(dif_toggle_t val) {
  switch (val) {
    case kDifToggleEnabled:
      return true;
    case kDifToggleDisabled:
      return false;
    default:
      return false;
  }
}

/**
 * Converts a `dif_toggle_t` to a `bool`.
 *
 * @param val A bool value.
 * @return Corresponding dif_toggle_t value.
 */
inline dif_toggle_t dif_bool_to_toggle(bool val) {
  return val ? kDifToggleEnabled : kDifToggleDisabled;
}

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  // OPENTITAN_SW_DEVICE_LIB_DIF_DIF_BASE_H_
