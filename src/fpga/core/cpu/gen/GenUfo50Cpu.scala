// UFO50 Pocket SoC CPU: VexRiscv RV32IMFD, 64 KB 2-way I$ + 32 KB 2-way D$ (defaults), machine mode only.
// Generator for SpinalHDL/VexRiscv (MIT). Output: VexRiscv.v with native cache buses
// (iBus_cmd/rsp, dBus_cmd/rsp), timerInterrupt, externalInterrupt, softwareInterrupt.
package vexriscv.demo

import spinal.core._
import vexriscv.ip.{DataCacheConfig, InstructionCacheConfig}
import vexriscv.ip.fpu.FpuParameter
import vexriscv.plugin._
import vexriscv.{VexRiscv, VexRiscvConfig, Riscv, plugin}

object GenUfo50Cpu extends App {
  def env(n: String, d: Int) = sys.env.get(n).map(_.toInt).getOrElse(d)
  val iKB   = env("ICACHE_KB", 64)
  val dKB   = env("DCACHE_KB", 32)
  val ways  = env("CACHE_WAYS", 2)
  val fpu   = env("FPU", 2)          // 0 none, 1 F, 2 F+D
  val misa  = Riscv.misaToInt("im" + (if (fpu >= 1) "f" else "") + (if (fpu >= 2) "d" else ""))

  def cpu() = new VexRiscv(VexRiscvConfig(plugins = List(
    new IBusCachedPlugin(
      resetVector = 0x00000000l,
      prediction = DYNAMIC_TARGET,
      historyRamSizeLog2 = 10,
      relaxPredictorAddress = true,
      relaxedPcCalculation = true,
      config = InstructionCacheConfig(
        cacheSize = iKB * 1024, bytePerLine = 32, wayCount = ways,
        addressWidth = 32, cpuDataWidth = 32, memDataWidth = 32,
        catchIllegalAccess = true, catchAccessFault = true,
        asyncTagMemory = false, twoCycleRam = false, twoCycleCache = true)),
    new DBusCachedPlugin(
      dBusCmdMasterPipe = true,
      dBusCmdSlavePipe = true,
      dBusRspSlavePipe = true,
      relaxedMemoryTranslationRegister = true,
      config = new DataCacheConfig(
        cacheSize = dKB * 1024, bytePerLine = 32, wayCount = ways,
        addressWidth = 32, cpuDataWidth = (if (fpu >= 2) 64 else 32), memDataWidth = env("DBUS_WIDTH", if (fpu >= 2) 64 else 32),
        catchAccessError = true, catchIllegal = true, catchUnaligned = true)),
    // 0x5xxxxxxx = uncached SDRAM alias, 0x8xxxxxxx = MMIO, 0xFxxxxxxx = unused
    new StaticMemoryTranslatorPlugin(ioRange = a => a(31 downto 28) === 0x5 || a(31) === True),
    new DecoderSimplePlugin(catchIllegalInstruction = true),
    new RegFilePlugin(regFileReadyKind = plugin.SYNC, zeroBoot = false, x0Init = true),
    new IntAluPlugin,
    new SrcPlugin(separatedAddSub = false, executeInsertion = true),
    new FullBarrelShifterPlugin(earlyInjection = false),
    new HazardSimplePlugin(
      bypassExecute = true, bypassMemory = true, bypassWriteBack = true, bypassWriteBackBuffer = true,
      pessimisticUseSrc = false, pessimisticWriteRegFile = false, pessimisticAddressMatch = false),
    new MulPlugin,
    new MulDivIterativePlugin(genMul = false, genDiv = true, mulUnrollFactor = 32, divUnrollFactor = 1),
    new CsrPlugin(CsrPluginConfig(
      catchIllegalAccess = true,
      mvendorid = 0, marchid = 0, mimpid = 0, mhartid = 0,
      misaExtensionsInit = misa, misaAccess = CsrAccess.READ_ONLY,
      mtvecAccess = CsrAccess.READ_WRITE, mtvecInit = 0x00000020l,
      mepcAccess = CsrAccess.READ_WRITE, mscratchGen = true,
      mcauseAccess = CsrAccess.READ_WRITE, mbadaddrAccess = CsrAccess.READ_WRITE,
      mcycleAccess = CsrAccess.READ_WRITE, minstretAccess = CsrAccess.READ_WRITE,
      ucycleAccess = CsrAccess.READ_ONLY, uinstretAccess = CsrAccess.READ_ONLY,
      ecallGen = true, ebreakGen = true, wfiGenAsWait = false, wfiGenAsNop = true)),
    new BranchPlugin(earlyBranch = false, catchAddressMisaligned = true, fenceiGenAsAJump = false)
  ) ++ (if (fpu >= 1) List(new FpuPlugin(externalFpu = false, p = FpuParameter(withDouble = fpu >= 2))) else Nil)))

  SpinalConfig(targetDirectory = sys.env.getOrElse("OUT", "."), oneFilePerComponent = false)
    .generateVerilog(cpu().setDefinitionName("VexRiscv"))
}
