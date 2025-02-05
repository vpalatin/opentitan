// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: entropy_src repetitive count health test module
//

module entropy_src_repcnt_ht #(
  parameter int RegWidth = 16,
  parameter int RngBusWidth = 4
) (
  input logic clk_i,
  input logic rst_ni,

   // ins req interface
  input logic [RngBusWidth-1:0] entropy_bit_i,
  input logic                   entropy_bit_vld_i,
  input logic                   clear_i,
  input logic                   active_i,
  input logic [RegWidth-1:0]    thresh_i,
  output logic [RegWidth-1:0]   test_cnt_o,
  output logic                  test_fail_pulse_o,
  output logic                  count_err_o
);

  // signals
  logic [RngBusWidth-1:0]               samples_match_pulse;
  logic [RngBusWidth-1:0]               samples_no_match_pulse;
  logic [RngBusWidth-1:0]               rep_cnt_fail;
  logic [RngBusWidth-1:0][RegWidth-1:0] rep_cntr;
  logic [RngBusWidth-1:0]               rep_cntr_err;
  logic [RegWidth-1:0]                  test_cnt;
  logic                                 test_cnt_err;
  logic [RegWidth-1:0]                  cntr_max;

  // flops
  logic [RngBusWidth-1:0] prev_sample_q, prev_sample_d;

  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin
      prev_sample_q    <= '0;
    end else begin
      prev_sample_q    <= prev_sample_d;
    end


  // Repetitive Count Test
  //
  // Test operation
  //  This test will look for catastrophic stuck bit failures. The rep_cntr
  //  uses one as the starting value, just as the NIST algorithm does.


  for (genvar sh = 0; sh < RngBusWidth; sh = sh+1) begin : gen_cntrs


    // NIST A sample
    assign prev_sample_d[sh] = (!active_i || clear_i) ? '0 :
                               entropy_bit_vld_i ? entropy_bit_i[sh] :
                               prev_sample_q[sh];

    assign samples_match_pulse[sh] = entropy_bit_vld_i &&
           (prev_sample_q[sh] == entropy_bit_i[sh]);
    assign samples_no_match_pulse[sh] = entropy_bit_vld_i &&
           (prev_sample_q[sh] != entropy_bit_i[sh]);

    // NIST B counter
    prim_count #(
      .Width(RegWidth),
      .OutSelDnCnt(1'b0), // count up
      .CntStyle(prim_count_pkg::DupCnt)
    ) u_prim_count_rep_cntr (
      .clk_i,
      .rst_ni,
      .clr_i(1'b0),
      .set_i(!active_i || clear_i || samples_no_match_pulse[sh]),
      .set_cnt_i(RegWidth'(1)),
      .en_i(samples_match_pulse[sh]),
      .step_i(RegWidth'(1)),
      .cnt_o(rep_cntr[sh]),
      .err_o(rep_cntr_err[sh])
    );

    assign rep_cnt_fail[sh] = (rep_cntr[sh] >= thresh_i);

  end : gen_cntrs

  entropy_src_comparator_tree #(
    .Width(RegWidth),
    .Depth(2)
  ) u_comp (
    .i(rep_cntr),
    .o(cntr_max)
  );

  // Test event counter
    prim_count #(
      .Width(RegWidth),
      .OutSelDnCnt(1'b0), // count up
      .CntStyle(prim_count_pkg::DupCnt)
    ) u_prim_count_test_cnt (
      .clk_i,
      .rst_ni,
      .clr_i(1'b0),
      .set_i(!active_i || clear_i),
      .set_cnt_i(RegWidth'(0)),
      .en_i(entropy_bit_vld_i && (|rep_cnt_fail)),
      .step_i(RegWidth'(1)),
      .cnt_o(test_cnt),
      .err_o(test_cnt_err)
    );

  // the pulses will be only one clock in length
  assign test_fail_pulse_o = active_i && entropy_bit_vld_i && (|rep_cnt_fail);
  assign test_cnt_o = cntr_max;
  assign count_err_o = test_cnt_err || (|rep_cntr_err);


endmodule
