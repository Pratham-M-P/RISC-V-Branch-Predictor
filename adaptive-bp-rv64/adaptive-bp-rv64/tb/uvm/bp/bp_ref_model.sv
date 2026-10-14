// -----------------------------------------------------------------------------
// bp_ref_model : cycle-accurate behavioural reference model of branch_predictor
//
//   Pure SystemVerilog class (no UVM dependency) so it can be used by the UVM
//   scoreboard *and* by the plain equivalence testbench (tb_bp_model_check.sv).
//   Written independently of the RTL structure: dynamic arrays + integer maths.
//
//   Usage per clock:   predict(pc, ...)   -> expected combinational outputs
//                      step(pc, adv, upd) -> advance state exactly like the clock edge
// -----------------------------------------------------------------------------
class bp_ref_model;
  // (bp_pkg::* must be imported by the enclosing package/module)

  int unsigned ptype, bim_w, gsh_w, cho_w, btb_w, tag_w, ras_d;

  bit [1:0]        bim [];
  bit [1:0]        gsh [];
  bit [1:0]        cho [];
  bit              btb_v   [];
  bit [63:0]       btb_tag [];
  br_type_e        btb_typ [];
  bit [63:0]       btb_tgt [];
  bit [63:0]       ras     [];
  int unsigned     ras_ptr;
  bit [15:0]       ghr;

  function new(int unsigned ptype = BP_TOURNAMENT, int unsigned bim_w = 10, int unsigned gsh_w = 10,
               int unsigned cho_w = 10, int unsigned btb_w = 6, int unsigned tag_w = 16,
               int unsigned ras_d = 8);
    this.ptype = ptype; this.bim_w = bim_w; this.gsh_w = gsh_w; this.cho_w = cho_w;
    this.btb_w = btb_w; this.tag_w = tag_w; this.ras_d = ras_d;
    bim = new[1 << bim_w]; gsh = new[1 << gsh_w]; cho = new[1 << cho_w];
    foreach (bim[i]) bim[i] = 2'b01;
    foreach (gsh[i]) gsh[i] = 2'b01;
    foreach (cho[i]) cho[i] = 2'b01;
    btb_v = new[1 << btb_w]; btb_tag = new[1 << btb_w]; btb_typ = new[1 << btb_w]; btb_tgt = new[1 << btb_w];
    foreach (btb_v[i]) begin btb_v[i] = 0; btb_tag[i] = 0; btb_typ[i] = BR_COND; btb_tgt[i] = 0; end
    ras = new[ras_d];
    foreach (ras[i]) ras[i] = 0;
    ras_ptr = 0;
    ghr = 0;
  endfunction

  // synchronous reset: only the pointer-type state is reset (tables keep their power-up contents)
  function void reset();
    ghr = 0;
    ras_ptr = 0;
  endfunction

  local function int unsigned ghr_mask();
    return (1 << gsh_w) - 1;
  endfunction

  local function int unsigned ix(bit [63:0] pc, int unsigned w);
    return int'((pc >> 2) & ((64'd1 << w) - 1));
  endfunction

  local function void btb_lookup(bit [63:0] pc, output bit hit, output br_type_e ty, output bit [63:0] tgt);
    int unsigned i = ix(pc, btb_w);
    bit [63:0] tag = (pc >> (2 + btb_w)) & ((64'd1 << tag_w) - 1);
    hit = btb_v[i] && (btb_tag[i] == tag);
    ty  = btb_typ[i];
    tgt = btb_tgt[i];
  endfunction

  local function bit [63:0] ras_top();
    return ras[(ras_ptr + ras_d - 1) % ras_d];
  endfunction

  function void predict(input bit [63:0] pc, output bit taken, output bit [63:0] target,
                        output bp_meta_t meta);
    bit hit; br_type_e ty; bit [63:0] btgt;
    bit bt, gt, dir;
    int unsigned gi;
    btb_lookup(pc, hit, ty, btgt);
    bt = bim[ix(pc, bim_w)][1];
    gi = (ix(pc, gsh_w) ^ int'(ghr & ghr_mask()));
    gt = gsh[gi][1];
    case (ptype)
      BP_BIMODAL:    dir = bt;
      BP_GSHARE:     dir = gt;
      BP_TOURNAMENT: dir = cho[ix(pc, cho_w)][1] ? gt : bt;
      default:       dir = 0;
    endcase
    taken  = (ptype != BP_NONE) && hit && ((ty != BR_COND) || dir);
    target = (ty == BR_RET) ? ras_top() : btgt;
    meta   = '0;
    meta.ghr       = ghr & ghr_mask();
    meta.bim_taken = bt;
    meta.gsh_taken = gt;
    meta.dir_taken = dir;
    meta.ras_ptr   = 4'(ras_ptr);
  endfunction

  function void step(input bit [63:0] pc, input bit adv, input bp_update_t u);
    bit hit; br_type_e ty; bit [63:0] btgt;
    bit bt, gt, dir;
    bit recover, spec_en, is_ctrl;
    int unsigned bi, gi, ci, rp;
    bit [15:0] ghr_new;

    btb_lookup(pc, hit, ty, btgt);
    bt  = bim[ix(pc, bim_w)][1];
    gi  = (ix(pc, gsh_w) ^ int'(ghr & ghr_mask()));
    gt  = gsh[gi][1];
    case (ptype)
      BP_BIMODAL:    dir = bt;
      BP_GSHARE:     dir = gt;
      BP_TOURNAMENT: dir = cho[ix(pc, cho_w)][1] ? gt : bt;
      default:       dir = 0;
    endcase

    recover = u.valid && u.mispredict;
    spec_en = adv && !recover && (ptype != BP_NONE) && hit;
    is_ctrl = u.is_cond || u.is_jal || u.is_jalr;

    // ---- counter training (read-modify-write at the *update* indices) --------------
    if (u.valid && u.is_cond) begin
      bit bim_ok = (u.meta.bim_taken == u.taken);
      bit gsh_ok = (u.meta.gsh_taken == u.taken);
      bi = ix(u.pc, bim_w);
      gi = (ix(u.pc, gsh_w) ^ int'(u.meta.ghr & ghr_mask()));
      ci = ix(u.pc, cho_w);
      if (bim_ok != gsh_ok) cho[ci] = sat_update(cho[ci], gsh_ok);
      bim[bi] = sat_update(bim[bi], u.taken);
      gsh[gi] = sat_update(gsh[gi], u.taken);
    end

    // ---- BTB ---------------------------------------------------------------------------------
    if (u.valid && ((is_ctrl && u.taken) || (!is_ctrl && u.mispredict))) begin
      int unsigned wi = ix(u.pc, btb_w);
      br_type_e wt;
      if      (u.is_ret)               wt = BR_RET;
      else if (u.is_call)              wt = BR_CALL;
      else if (u.is_jal || u.is_jalr)  wt = BR_JUMP;
      else                             wt = BR_COND;
      btb_v[wi] = is_ctrl;
      if (is_ctrl) begin
        btb_tag[wi] = (u.pc >> (2 + btb_w)) & ((64'd1 << tag_w) - 1);
        btb_typ[wi] = wt;
        btb_tgt[wi] = u.target;
      end
    end

    // ---- speculative state: GHR + RAS ----------------------------------------------------
    ghr_new = ghr;
    if (recover) begin
      bit [16:0] cat = {u.meta.ghr, u.taken};
      ghr_new = u.is_cond ? 16'(cat) : u.meta.ghr;
      ghr_new = ghr_new & ghr_mask();
      rp = int'(u.meta.ras_ptr) % ras_d;
      if (u.is_call) begin
        ras[rp] = u.pc + 4;
        ras_ptr = (rp + 1) % ras_d;
      end else if (u.is_ret) begin
        ras_ptr = (rp + ras_d - 1) % ras_d;
      end else begin
        ras_ptr = rp;
      end
    end else if (spec_en) begin
      if (ty == BR_COND) ghr_new = ((ghr << 1) | dir) & ghr_mask();
      if (ty == BR_CALL) begin ras[ras_ptr] = pc + 4; ras_ptr = (ras_ptr + 1) % ras_d; end
      if (ty == BR_RET)  begin ras_ptr = (ras_ptr + ras_d - 1) % ras_d; end
    end
    ghr = ghr_new;
  endfunction
endclass
