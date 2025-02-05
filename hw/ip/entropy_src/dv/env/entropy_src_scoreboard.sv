// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class entropy_src_scoreboard extends cip_base_scoreboard
  #(
    .CFG_T(entropy_src_env_cfg),
    .RAL_T(entropy_src_reg_block),
    .COV_T(entropy_src_env_cov)
  );
  import entropy_src_pkg::*;

  `uvm_component_utils(entropy_src_scoreboard)

  // used by collect_entropy to determine the FSMs phase
  int seed_idx                = 0;
  int entropy_data_seeds      = 0;
  int entropy_data_drops      = 0;
  int csrng_seeds             = 0;
  int csrng_drops             = 0;

  // Queue of seeds for predicting reads to entropy_data CSR
  bit [CSRNG_BUS_WIDTH - 1:0]      entropy_data_q[$];

  // The most recent candidate seed from entropy_data_q
  // At each TL read the TL data item is compared to the appropriate
  // 32-bit segment of this seed (as determented by seed_tl_read_cnt)
  bit [CSRNG_BUS_WIDTH - 1:0]      tl_best_seed_candidate;

  // The previous output seed.  We need to track this to determine whether to expect "recov_alert"
  bit [CSRNG_BUS_WIDTH - 1:0]      prev_csrng_seed;

  // Number of 32-bit TL reads to the current (active) seed
  // Ranges from 0 (no data read out) to CSRNG_BUS_WIDTH/TL_DW (seed fully read out)
  int                              seed_tl_read_cnt = 0;

  bit [FIPS_CSRNG_BUS_WIDTH - 1:0] fips_csrng_q[$];

  // TODO: Document Initial Conditions for health check.
  // This should make no practical difference, but it is important for successful verification.
  rng_val_t                        prev_rng_val = '0;
  int                              repcnt      [RNG_BUS_WIDTH];
  int                              repcnt_symbol;
  int                              max_repcnt, max_repcnt_symbol;

  // TLM agent fifos
  uvm_tlm_analysis_fifo#(push_pull_item#(.HostDataWidth(FIPS_CSRNG_BUS_WIDTH)))
      csrng_fifo;
  uvm_tlm_analysis_fifo#(push_pull_item#(.HostDataWidth(RNG_BUS_WIDTH)))
      rng_fifo;

  `uvm_component_new

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    rng_fifo   = new("rng_fifo", this);
    csrng_fifo = new("csrng_fifo", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    if (cfg.en_scb) begin
      fork
        collect_entropy();
        process_csrng();
      join_none
    end
  endtask

  //
  // Health check test routines
  //

  task update_repcnts(rng_val_t rng_val);
    for (int i = 0; i < RNG_BUS_WIDTH; i++) begin
      if (rng_val[i] == prev_rng_val[i]) begin
        repcnt[i]++;
        max_repcnt = (repcnt[i] > max_repcnt) ? repcnt[i] : max_repcnt;
      end else begin
        repcnt[i] = 1;
      end
    end
    if (rng_val == prev_rng_val) begin
      repcnt_symbol++;
    end else begin
      repcnt_symbol = 1;
    end
    prev_rng_val = rng_val;
    max_repcnt_symbol = (repcnt_symbol > max_repcnt_symbol) ? repcnt_symbol : max_repcnt_symbol;
  endtask

  // TODO: Revisit after resolution of #9759
  function int calc_adaptp_test(queue_of_rng_val_t window);
    int result = '0;
    for (int i = 0; i < window.size(); i++) begin
      for (int j = 0; j < RNG_BUS_WIDTH; j++) begin
         result += window[i][j];
      end
    end
    return result;
  endfunction

  function int calc_bucket_test(queue_of_rng_val_t window);
    int bin_count = (1 << RNG_BUS_WIDTH);
    int result[$];

    int buckets [] = new [bin_count];

    for (int i = 0; i < window.size(); i++) begin
      int elem = window[i];
      buckets[elem]++;
    end

    for (int i = 0; i < bin_count; i++) begin
      `uvm_info(`gfn, $sformatf("Bucket test. bin: %01h, value: %02h", i, buckets[i]), UVM_FULL)
    end

    result = buckets.max();

    `uvm_info(`gfn, $sformatf("Bucket test. max value: %02h", result[0]), UVM_FULL)

    return result[0];
  endfunction

  function int calc_markov_test(queue_of_rng_val_t window, output int maxval, output int minval);
    int pair_cnt[RNG_BUS_WIDTH];
    int minq[$], maxq[$];
    for (int i = 0; i < window.size(); i += 2) begin
      for (int j = 0; j < RNG_BUS_WIDTH; j++) begin
        bit different = window[i][j] ^ window[i + 1][j];
        pair_cnt[j] += different;
      end
    end
    maxq = pair_cnt.max();
    maxval = maxq[0];
    minq = pair_cnt.min();
    minval = minq[0];
    return pair_cnt.sum();
  endfunction

  function int calc_extht_test(queue_of_rng_val_t window);
    // TODO
    int result = 0;
    return result;
  endfunction

  //
  // Debug tool: make sure that the following helper functions use proper names for health checks.
  //
  function void validate_test_name(string name);
    bit is_valid;
    is_valid = (name == "adaptp_hi") ||
               (name == "adaptp_lo") ||
               (name == "bucket"   ) ||
               (name == "markov_hi") ||
               (name == "markov_lo") ||
               (name == "extht_hi" ) ||
               (name == "extht_lo" ) ||
               (name == "repcnt"   ) ||
               (name == "repcnts"  );
    `DV_CHECK_EQ(is_valid, 1, $sformatf("invalid test name: %s\n", name))
  endfunction

  function bit is_low_test(string name);
    int len = name.len();
    return (name.substr(len - 3, len - 1) == "_lo");
  endfunction

  // Operate on the watermark for a given test, using the mirrored copy of the corresponding
  // watermark register.
  //
  // If the value exceeds (or is less then) the latest watermark value, then update the prediction.
  //
  // Implements predictions for all registers named <test>_watermarks.
  function void update_watermark(string test, bit fips_mode, int value);
    string        watermark_field_name;
    string        watermark_reg_name;
    uvm_reg       watermark_reg;
    uvm_reg_field watermark_field;
    int           watermark_val;
    bit           low_test;
    string        fmt;


    validate_test_name(test);

    // The watermark registers for repcnt, repcnts and bucket tests deviate from the
    // general convention of suppressing the "_hi" suffix for tests that do not have a low
    // threshold.
    if ((test == "repcnt") || (test == "repcnts") || (test == "bucket")) begin
      test = {test, "_hi"};
    end

    watermark_field_name = fips_mode ? "fips_watermark" : "bypass_watermark";
    watermark_reg_name   = $sformatf("%s_watermarks", test);
    watermark_reg        = ral.get_reg_by_name(watermark_reg_name);
    watermark_field      = watermark_reg.get_field_by_name(watermark_field_name);
    watermark_val        = watermark_field.get_mirrored_value();
    low_test             = is_low_test(test);

    if (low_test) begin : low_watermark_check
      if (value < watermark_val) begin
        fmt = "Predicted LO watermark for \"%s\" test (FIPS? %d): %04h";
        `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, value), UVM_HIGH)
        `DV_CHECK_FATAL(watermark_field.predict(.value(value), .kind(UVM_PREDICT_READ)))
      end else begin
        fmt = "LO watermark unchanged for \"%s\" test (FIPS? %d): %04h";
        `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, watermark_val), UVM_HIGH)
      end
    end else begin : high_watermark_check
      if (value > watermark_val) begin
        string fmt;
        fmt = "Predicted HI watermark for \"%s\" test (FIPS? %d): %04h";
        `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, value), UVM_HIGH)
        `DV_CHECK_FATAL(watermark_field.predict(.value(value), .kind(UVM_PREDICT_READ)))
      end else begin
        fmt = "HI watermark unchanged for \"%s\" test (FIPS? %d): %04h";
        `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, watermark_val), UVM_HIGH)
      end
    end : high_watermark_check

  endfunction

  // Compare a particular health check value against the corresponding thresholds.
  // If the health check fails, log the failure and update our predictions for the alert registers.
  //
  // Implements predictions for all registers named:
  // <test>_total_fails
  // alert_fail_counts.<test>_fail_count
  // extht_fail_counts.<test>_fail_count
  //
  // Because failing multiple  tests for a single test only count as one total alert failure
  // this routine does not update alert_summary_fail_counts
  //
  function bit check_threshold(string test, bit fips_mode, int value);
    string        threshold_reg_name;
    string        threshold_field_name;
    string        total_fail_reg_name;
    string        total_fail_field_name;
    string        alert_cnt_reg_name;
    string        alert_cnt_field_name;
    uvm_reg       threshold_reg;
    uvm_reg       total_fail_reg;
    uvm_reg       alert_cnt_reg;
    uvm_reg_field threshold_field;
    uvm_reg_field total_fail_field;
    uvm_reg_field alert_cnt_field;

    int        threshold_val;
    bit [3:0]  alert_cnt;
    int        fail_total;
    bit        continuous_test;
    bit        failure;
    bit        low_test;
    string     fmt;

    validate_test_name(test);
    low_test             = is_low_test(test);
    continuous_test      = (test == "repcnt") || (test == "repcnts");

    // TODO: confirm that the FIPS threshold is the only one that matters for the continuous tests.
    // Having split thresholds doesn't matter for such tests.
    threshold_field_name = (fips_mode || continuous_test) ? "fips_thresh" : "bypass_thresh";
    threshold_reg_name  = $sformatf("%s_thresholds", test);

    total_fail_reg_name = $sformatf("%s_total_fails", test);
    total_fail_field_name = total_fail_reg_name;

    // Most tests have field in the alert_fail_counts register, except extht_fail_counts
    if (test.substr(0, 5) == "extht_") begin
      alert_cnt_reg_name = "extht_fail_counts";
    end else begin
      alert_cnt_reg_name = "alert_fail_counts";
    end
    alert_cnt_field_name = $sformatf("%s_fail_count", test);

    threshold_reg    = ral.get_reg_by_name(threshold_reg_name);
    threshold_field  = threshold_reg.get_field_by_name(threshold_field_name);

    total_fail_reg   = ral.get_reg_by_name(total_fail_reg_name);
    total_fail_field = total_fail_reg.get_field_by_name(total_fail_field_name);

    alert_cnt_reg    = ral.get_reg_by_name(alert_cnt_reg_name);
    alert_cnt_field  = alert_cnt_reg.get_field_by_name(alert_cnt_field_name);

    threshold_val = threshold_field.get_mirrored_value();

    failure = (low_test && value < threshold_val) || (!low_test && value > threshold_val);

    fail_total = total_fail_field.get_mirrored_value();
    alert_cnt  =  alert_cnt_field.get_mirrored_value();

    if (failure) begin
      alert_cnt++;
      fail_total++;
    end else begin
      alert_cnt = 0;
    end

    fmt = "Threshold for \"%s\" test (FIPS? %d): %04h";
    `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, threshold_val), UVM_HIGH)

    fmt = "Observed Val for \"%s\" test (FIPS? %d): %04h, %s";
    `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, value, failure ? "FAIL" : "PASS"), UVM_HIGH)

    fmt = "Predicted alert cnt for \"%s\" test (FIPS? %d): %04h";
    `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, alert_cnt), UVM_HIGH)

    fmt = "Predicted fail cnt for \"%s\" test (FIPS? %d): %04h";
    `uvm_info(`gfn, $sformatf(fmt, test, fips_mode, fail_total), UVM_HIGH)

    `DV_CHECK_FATAL(total_fail_field.predict(.value(fail_total), .kind(UVM_PREDICT_READ)))
    `DV_CHECK_FATAL( alert_cnt_field.predict(.value( alert_cnt), .kind(UVM_PREDICT_READ)))

  endfunction

  // TODO: Revisit after resolution of #9759
  function bit evaluate_adaptp_test(queue_of_rng_val_t window, bit fips_mode);
    int value;
    bit fail_hi, fail_lo;

    value = calc_adaptp_test(window);

    update_watermark("adaptp_lo", fips_mode, value);
    update_watermark("adaptp_hi", fips_mode, value);

    fail_lo = check_threshold("adaptp_lo", fips_mode, value);
    fail_hi = check_threshold("adaptp_hi", fips_mode, value);

    return (fail_hi || fail_lo);
  endfunction

  function bit evaluate_bucket_test(queue_of_rng_val_t window, bit fips_mode);
    int value;
    bit fail;

    value = calc_bucket_test(window);

    update_watermark("bucket", fips_mode, value);

    fail = check_threshold("bucket", fips_mode, value);

    return fail;
  endfunction

  // TODO: Revisit after resolution of #9759
  function bit evaluate_markov_test(queue_of_rng_val_t window, bit fips_mode);
    int value, minval, maxval;
    bit fail_hi, fail_lo;

    value = calc_markov_test(window, maxval, minval);

    update_watermark("markov_lo", fips_mode, minval);
    update_watermark("markov_hi", fips_mode, maxval);

    fail_lo = check_threshold("markov_lo", fips_mode, value);
    fail_hi = check_threshold("markov_hi", fips_mode, value);

    return (fail_hi || fail_lo);
  endfunction

  function evaluate_external_ht(queue_of_rng_val_t window, bit fips_mode);
    int value;
    bit fail_hi, fail_lo;

    value = calc_extht_test(window);

    update_watermark("extht_lo", fips_mode, value);
    update_watermark("extht_hi", fips_mode, value);

    fail_lo = check_threshold("extht_lo", fips_mode, value);
    fail_hi = check_threshold("extht_hi", fips_mode, value);

    return (fail_hi || fail_lo);
  endfunction

  // The repetition counts are always running
  function bit evaluate_repcnt_test(bit fips_mode);
    int value;
    bit fail;

    value = max_repcnt;

    update_watermark("repcnt", fips_mode, value);

    fail = check_threshold("repcnt", fips_mode, value);

    return fail;
  endfunction

  function bit evaluate_repcnt_symbol_test(bit fips_mode);
    int value;
    bit fail;

    value = max_repcnt_symbol;

    update_watermark("repcnts", fips_mode, value);

    fail = check_threshold("repcnts", fips_mode, value);

    return fail;
  endfunction

  function bit health_check_rng_data(queue_of_rng_val_t window, bit fips_mode);
    int failcnt = 0;
    bit failure = 0;
    uvm_reg       alert_summary_reg   = ral.get_reg_by_name("alert_summary_fail_counts");
    uvm_reg_field alert_summary_field = alert_summary_reg.get_field_by_name("any_fail_count");
    string        fmt;
    int           any_fail_count_regval;

    failcnt += evaluate_repcnt_test(fips_mode);
    failcnt += evaluate_repcnt_symbol_test(fips_mode);
    failcnt += evaluate_adaptp_test(window, fips_mode);
    failcnt += evaluate_bucket_test(window, fips_mode);
    failcnt += evaluate_markov_test(window, fips_mode);
    failcnt += evaluate_external_ht(window, fips_mode);

    failure = (failcnt != 0);

    any_fail_count_regval = alert_summary_field.get_mirrored_value();
    if (failure) begin
      any_fail_count_regval++;
    end else begin
      any_fail_count_regval = 0;
    end

    fmt = "Predicted alert cnt for all tests (FIPS? %d): %04h";
    `uvm_info(`gfn, $sformatf(fmt, fips_mode, any_fail_count_regval), UVM_HIGH)

    `DV_CHECK_FATAL(alert_summary_field.predict(.value(any_fail_count_regval),
                                                .kind(UVM_PREDICT_READ)))
    // TODO: Anticipate alerts if any_fail_count crosses the threshold
    // TODO: If an alert is anticipated, we should check that this (if necessary this seed is
    // stopped and no others are allowed to progress.
    return failure;
  endfunction

  //
  // Helper function for process_entropy_data_access
  //

  function bit try_seed_tl(input bit [CSRNG_BUS_WIDTH - 1:0] new_candidate,
                           input bit [TL_DW - 1:0] tl_data,
                           output bit [TL_DW - 1:0] tl_prediction);
    bit [CSRNG_BUS_WIDTH - 1:0] mask, new_seed_masked, best_seed_masked;
    bit matches_prev_reads;
    bit matches_tl_data;
    string fmt;

    mask = '0;

    for(int i = 0; i < seed_tl_read_cnt; i++) begin
      mask[i * TL_DW +: TL_DW] = {TL_DW{1'b1}};
    end
    new_seed_masked = (new_candidate & mask);
    best_seed_masked = (tl_best_seed_candidate & mask);
    matches_prev_reads = (best_seed_masked == new_seed_masked);

    if (matches_prev_reads) begin
      // Only log this if the new seed is different from the previous best:
      if (new_candidate != tl_best_seed_candidate) begin
        string fmt = "Found another match candidate after %01d total dropped seeds";
       `uvm_info(`gfn, $sformatf(fmt, entropy_data_drops), UVM_HIGH)
      end
    end else begin
      `uvm_info(`gfn, "New candidate seed does not match previous segments", UVM_HIGH)
      fmt = "New seed: %096h, Best seed: %096h";
      // In the log mask out portions that have not been compared yet, for contrast
      `uvm_info(`gfn, $sformatf(fmt, new_seed_masked, best_seed_masked), UVM_HIGH)
       return 0;
    end

    tl_prediction = new_candidate[TL_DW * seed_tl_read_cnt +: TL_DW];
    matches_tl_data = (tl_prediction == tl_data);

    if (tl_prediction == tl_data) begin
      tl_best_seed_candidate = new_candidate;
      fmt = "Seed matches TL data after %d TL reads";
      `uvm_info(`gfn, $sformatf(fmt, seed_tl_read_cnt+1), UVM_HIGH)
      return 1;
    end else begin
      fmt = "TL DATA (%08h) does not match predicted seed segment (%08h)";
      `uvm_info(`gfn, $sformatf(fmt, tl_data, tl_prediction), UVM_HIGH)
      return 0;
    end

  endfunction

  // Helper routine for process_tl_access
  //
  // Since the DUT may, by design, internally drop data, it is not sufficient to check against
  // one seed, we compare TL data values against all available seeds.
  // If no match is found then the access is in error.
  //
  task process_entropy_data_access(tl_seq_item item, uvm_reg csr);

    bit [TL_DW - 1:0] ed_pred_data;
    bit               match_found;

    match_found = 0;

    while (entropy_data_q.size() > 0) begin : seed_trial_loop
      bit [TL_DW - 1:0] prediction;
      `uvm_info(`gfn, $sformatf("seed_tl_read_cnt: %01d", seed_tl_read_cnt), UVM_FULL)
      match_found = try_seed_tl(entropy_data_q[0], item.d_data, prediction);
      if (match_found) begin
        `DV_CHECK_FATAL(csr.predict(.value(prediction), .kind(UVM_PREDICT_READ)))
        seed_tl_read_cnt++;
        if (seed_tl_read_cnt == CSRNG_BUS_WIDTH / TL_DW) begin
          seed_tl_read_cnt = 0;
          entropy_data_q.pop_front();
          entropy_data_seeds++;
        end else if (seed_tl_read_cnt > CSRNG_BUS_WIDTH / TL_DW) begin
          `uvm_error(`gfn, "testbench error: too many segments read from candidate seed")
        end
        break;
      end else begin
        entropy_data_q.pop_front();
        entropy_data_drops++;
      end
    end : seed_trial_loop

    `DV_CHECK_NE(match_found, 0,
                "All candidate seeds have been checked.  ENTROPY_DATA does not match")
  endtask

  virtual task process_tl_access(tl_seq_item item, tl_channels_e channel, string ral_name);
    uvm_reg csr;
    // TODO: Add conditioning prediction, still TBD in design
    bit do_read_check       = 1'b1;
    bit write               = item.is_write();
    uvm_reg_addr_t csr_addr = cfg.ral_models[ral_name].get_word_aligned_addr(item.a_addr);

    // if access was to a valid csr, get the csr handle
    if (csr_addr inside {cfg.ral_models[ral_name].csr_addrs}) begin
      csr = cfg.ral_models[ral_name].default_map.get_reg_by_offset(csr_addr);
      `DV_CHECK_NE_FATAL(csr, null)
    end else begin
      `uvm_fatal(`gfn, $sformatf("Access unexpected addr 0x%0h", csr_addr))
    end

    if (channel == AddrChannel) begin
      // if incoming access is a write to a valid csr, then make updates right away
      if (write) begin
        void'(csr.predict(.value(item.a_data), .kind(UVM_PREDICT_WRITE), .be(item.a_mask)));
      end
    end

    // process the csr req
    // for write, update local variable and fifo at address phase
    // for read, update predication at address phase and compare at data phase
    case (csr.get_name())
      // add individual case item for each csr
      "intr_state": begin
        // TODO
        do_read_check = 1'b0;
      end
      "intr_enable": begin
      end
      "intr_test": begin
      end
      "regwen": begin
      end
      "conf": begin
      end
      "rev": begin
      end
      "rate": begin
      end
      "entropy_control": begin
      end
      "entropy_data": begin
      end
      "health_test_windows": begin
      end
      "repcnt_thresholds": begin
      end
      "repcnts_thresholds": begin
      end
      "adaptp_hi_thresholds": begin
      end
      "adaptp_lo_thresholds": begin
      end
      "bucket_thresholds": begin
      end
      "markov_hi_thresholds": begin
      end
      "markov_lo_thresholds": begin
      end
      "repcnt_hi_watermarks": begin
        // TODO: KNOWN ISSUE: pending resolution to #9819
        do_read_check = 1'b0;
      end
      "repcnts_hi_watermarks": begin
        // TODO: KNOWN ISSUE: pending resolution to #9819
        do_read_check = 1'b0;
      end
      "adaptp_hi_watermarks": begin
      end
      "adaptp_lo_watermarks": begin
      end
      "bucket_hi_watermarks": begin
      end
      "markov_hi_watermarks": begin
      end
      "markov_lo_watermarks": begin
      end
      "extht_hi_watermarks": begin
      end
      "extht_lo_watermarks": begin
      end
      "repcnt_total_fails": begin
      end
      "repcnts_total_fails": begin
      end
      "adaptp_hi_total_fails": begin
      end
      "adaptp_lo_total_fails": begin
      end
      "bucket_total_fails": begin
      end
      "markov_hi_total_fails": begin
      end
      "markov_lo_total_fails": begin
      end
      "extht_hi_total_fails": begin
      end
      "extht_lo_total_fails": begin
      end
      "alert_threshold": begin
      end
      "alert_fail_counts": begin
      end
      "extht_fail_counts": begin
      end
      "fw_ov_control": begin
      end
      "fw_ov_rd_data": begin
      end
      "fw_ov_wr_data": begin
      end
      "observe_fifo_thresh": begin
      end
      "debug_status": begin
      end
      "recov_alert_sts": begin
        do_read_check = 1'b0;
      end
      "err_code": begin
      end
      "err_code_check": begin
      end
      default: begin
        `uvm_fatal(`gfn, $sformatf("invalid csr: %0s", csr.get_full_name()))
      end
    endcase

    // On reads, if do_read_check is set, then check mirrored_value against item.d_data
    if (!write && channel == DataChannel) begin
      if (do_read_check) begin
        case (csr.get_name())
          "entropy_data": begin
            process_entropy_data_access(item, csr);
          end
        endcase

        `DV_CHECK_EQ(csr.get_mirrored_value(), item.d_data,
                     $sformatf("reg name: %0s", csr.get_full_name()))
      end
    end
  endtask

  function bit [FIPS_BUS_WIDTH - 1:0] get_fips_compliance(
      bit [FIPS_CSRNG_BUS_WIDTH - 1:0] fips_csrng);
    return fips_csrng[CSRNG_BUS_WIDTH +: FIPS_BUS_WIDTH];
  endfunction

  function bit [CSRNG_BUS_WIDTH - 1:0] get_csrng_seed(bit [FIPS_CSRNG_BUS_WIDTH - 1:0] fips_csrng);
    return fips_csrng[0 +: CSRNG_BUS_WIDTH];
  endfunction

  // Note: this routine is destructive in that it empties the input argument
  function bit [FIPS_CSRNG_BUS_WIDTH - 1:0] predict_fips_csrng(ref queue_of_rng_val_t sample);
    bit [FIPS_CSRNG_BUS_WIDTH - 1:0] fips_csrng_data;
    bit [CSRNG_BUS_WIDTH - 1:0]      csrng_data;
    bit [FIPS_BUS_WIDTH - 1:0]       fips_data;
    entropy_phase_e                  dut_phase;
    bit                              predict_conditioned;

    int                              sample_rng_frames;
    int                              pass_cnt_threshold;
    int                              pass_cnt;

    dut_phase = convert_seed_idx_to_phase(seed_idx,
                                          cfg.boot_bypass_disable == prim_mubi_pkg::MuBi4True);

    sample_rng_frames = sample.size();

    `uvm_info(`gfn, $sformatf("processing %01d frames", sample_rng_frames), UVM_FULL)

    predict_conditioned = (cfg.type_bypass != prim_mubi_pkg::MuBi4True) && (dut_phase != BOOT);

    // TODO: for now assume that data is fips certified if it has been conditioned
    //       need to check that no other conditions apply for released data.
    fips_data    = predict_conditioned;

    if (predict_conditioned) begin
      int rng_per_byte = 8 / RNG_BUS_WIDTH;

      bit [7:0] sha_msg[];
      bit [7:0] sha_digest[CSRNG_BUS_WIDTH / 8];
      longint msg_len = 0;

      sha_msg = new[sample.size() / rng_per_byte];

      while (sample.size() > 0) begin
        bit [7:0] sha_byte = '0;
        for (int i = 0; i < rng_per_byte; i++) begin
          sha_byte = (sha_byte >> RNG_BUS_WIDTH);
          sha_byte = sha_byte | (sample.pop_front() << (8 - RNG_BUS_WIDTH));
        end
        `uvm_info(`gfn, $sformatf("msglen: %04h, byte: %02h", msg_len, sha_byte), UVM_FULL)
        sha_msg[msg_len] = sha_byte;
        msg_len++;
      end

      `uvm_info(`gfn, $sformatf("DIGESTION COMMENCING of %d bytes", msg_len), UVM_FULL)

      digestpp_dpi_pkg::c_dpi_sha3_384(sha_msg, msg_len, sha_digest);

      `uvm_info(`gfn, "DIGESTING COMPLETE", UVM_FULL)

      csrng_data = '0;
      for(int i = 0; i < CSRNG_BUS_WIDTH / 8; i++) begin
        bit [7:0] sha_byte = sha_digest[i];

        `uvm_info(`gfn, $sformatf("repacking: %02d", i), UVM_FULL)

        csrng_data = (csrng_data >> 8) | (sha_byte << (CSRNG_BUS_WIDTH - 8));
      end
      `uvm_info(`gfn, $sformatf("Conditioned data: %096h", csrng_data), UVM_HIGH)

    end else begin

      while (sample.size() > 0) begin
        rng_val_t rng_val = sample.pop_back();
        string fmt = "sample size: %01d, last elem.: %01h";
        // Since the queue is read from back to front
        // earlier rng bits occupy the less significant bits of csrng_data

        `uvm_info(`gfn, $sformatf(fmt, sample.size()+1, rng_val), UVM_FULL)
        csrng_data = (csrng_data << RNG_BUS_WIDTH) + rng_val;
      end
      `uvm_info(`gfn, $sformatf("Unconditioned data: %096h", csrng_data), UVM_HIGH)

    end

    fips_csrng_data = {fips_data, csrng_data};

    return fips_csrng_data;
  endfunction

  task collect_entropy();

    bit [15:0]                window_size;
    entropy_phase_e           dut_fsm_phase;
    push_pull_item#(.HostDataWidth(RNG_BUS_WIDTH))  rng_item;
    rng_val_t                 rng_val;
    // TODO rename window to "sample"
    queue_of_rng_val_t        window;
    queue_of_rng_val_t        sample;
    int                       window_rng_frames;
    int                       pass_requirement, pass_cnt;
    int                       retry_limit, retry_cnt;
    bit                       ht_fips_mode;

    retry_cnt = 0;
    pass_cnt  = 0;

    window.delete();
    sample.delete();

    forever begin : collect_entropy_loop

      dut_fsm_phase = convert_seed_idx_to_phase(seed_idx,
          cfg.boot_bypass_disable == prim_mubi_pkg::MuBi4True);

      if(cfg.type_bypass == prim_mubi_pkg::MuBi4True) begin
        retry_limit          = 2;
        pass_requirement     = 0;
        ht_fips_mode         = 0;
      end else begin
        case (dut_fsm_phase)
          BOOT: begin
            pass_requirement = 1;
            retry_limit      = cfg.boot_mode_retry_limit;
            ht_fips_mode     = 0;
          end
          STARTUP: begin
            pass_requirement = 2;
            retry_limit      = 2;
            ht_fips_mode     = 1;
          end
          CONTINUOUS: begin
            pass_requirement = 0;
            retry_limit      = 2;
            ht_fips_mode     = 1;
          end
          default: begin
            `uvm_fatal(`gfn, "Invalid predicted dut state (bug in environment)")
          end
        endcase
      end

      `uvm_info(`gfn, $sformatf("phase: %s\n", dut_fsm_phase.name), UVM_HIGH)

      window_size = rng_window_size(seed_idx, cfg.type_bypass == prim_mubi_pkg::MuBi4True,
                                    cfg.boot_bypass_disable == prim_mubi_pkg::MuBi4True,
                                    cfg.fips_window_size);

      `uvm_info(`gfn, $sformatf("window_size: %08d\n", window_size), UVM_HIGH)

      // Note on RNG bit enable and window frame count:
      // When rng_bit_enable is selected, the function below repacks the data so that
      // the selected bit fills a whole frame.
      // This mirrors the DUT's behavior of repacking the data before the health checks
      //
      // Thus the number of (repacked) window frames is the same regardless of whether
      // the bit select is enabled.

      window_rng_frames = window_size / RNG_BUS_WIDTH;

      window.delete();
      if(dut_fsm_phase != STARTUP) begin
        sample.delete();
      end

      while (window.size() < window_rng_frames) begin
        if (cfg.rng_bit_enable == prim_mubi_pkg::MuBi4True) begin
          for (int i = 0; i < RNG_BUS_WIDTH; i++) begin
            rng_fifo.get(rng_item);
            rng_val[i] = rng_item.h_data[cfg.rng_bit_sel];
          end
        end else begin
          rng_fifo.get(rng_item);
          rng_val = rng_item.h_data;
        end
        window.push_back(rng_val);
        // The repetition count is updated continuously.
        // The other health checks only operate on complete windows, and are processed later.
        update_repcnts(rng_val);
      end

     `uvm_info(`gfn, "FULL_WINDOW", UVM_FULL)
      if (health_check_rng_data(window, ht_fips_mode)) begin
        retry_cnt++;
        pass_cnt = 0;
      end else begin
        retry_cnt = 0;
        pass_cnt++;
      end

      // Now that the window has been tested, add it to the running sample.
      while(window.size() > 0) begin
        sample.push_back(window.pop_front());
      end

      `uvm_info(`gfn, $sformatf("pass_cnt: %01d, retry_cnt: %01d", pass_cnt, retry_cnt), UVM_HIGH)
      `uvm_info(`gfn, $sformatf("pass_requirement: %01d", pass_requirement), UVM_HIGH)
      `uvm_info(`gfn, $sformatf("retry_limit: %01d", retry_limit), UVM_HIGH)
      `uvm_info(`gfn, $sformatf("sample.size: %01d", sample.size()), UVM_HIGH)

      // TODO: Update health check stats.
      if (retry_cnt >= retry_limit) begin
        // TODO: Alert state
        `uvm_info(`gfn, "TODO: manage alerts", UVM_FULL)
      end else if (pass_cnt >= pass_requirement) begin
        bit [FIPS_CSRNG_BUS_WIDTH - 1:0] fips_csrng;
        bit [CSRNG_BUS_WIDTH - 1:0] csrng_seed;

        fips_csrng = predict_fips_csrng(sample);
        `uvm_info(`gfn, $sformatf("sample.size(): %01d", sample.size()), UVM_FULL)

        // update counters for processing next seed:
        retry_cnt = 0;
        pass_cnt  = 0;
        seed_idx++;

        // package data for routing to SW and to CSRNG:
        csrng_seed = get_csrng_seed(fips_csrng);
        entropy_data_q.push_back(csrng_seed);
        fips_csrng_q.push_back(fips_csrng);

        // Check to see whether a recov_alert should be expected
        if (dut_fsm_phase != BOOT && csrng_seed == prev_csrng_seed) begin
          set_exp_alert(.alert_name("recov_alert"), .is_fatal(0), .max_delay(cfg.alert_max_delay));
        end

        prev_csrng_seed = csrng_seed;

      end else begin
        // Inconsequential health check failure
      end

    end : collect_entropy_loop

  endtask

  virtual task process_csrng();
    push_pull_item#(.HostDataWidth(FIPS_CSRNG_BUS_WIDTH))  item;
   `uvm_info(`gfn, "task \"process_csrng\" starting\n", UVM_FULL)

    forever begin
      bit match_found = 0;

      csrng_fifo.get(item);
      `uvm_info(`gfn, $sformatf("process_csrng: new item: %096h\n", item.d_data), UVM_HIGH)

      while (fips_csrng_q.size() > 0) begin : seed_trial_loop
        bit [FIPS_CSRNG_BUS_WIDTH - 1:0] prediction;
        // Unlike in the TL case, there is no need to leave seed predictions in the queue.
        prediction = fips_csrng_q.pop_front();
        if (prediction == item.d_data) begin
          csrng_seeds++;
          match_found = 1;
          `uvm_info(`gfn, $sformatf("Match found: %d\n", csrng_seeds), UVM_FULL)
        end else begin
          csrng_drops++;
          `uvm_info(`gfn, $sformatf("Dropped seed: %d\n", csrng_drops), UVM_FULL)
        end
      end : seed_trial_loop
      `DV_CHECK_EQ_FATAL(match_found, 1)
    end
  endtask

  virtual function void reset(string kind = "HARD");
    super.reset(kind);
    // reset local fifos queues and variables
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    // post test checks - ensure that all local fifos and queues are empty
  endfunction

endclass
