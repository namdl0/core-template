#!/bin/sh
# build_offline.sh - regenerate cpu/VexRiscv.v WITHOUT sbt/Maven (how M3's file was made).
#
# Needs: a JDK (17 or 21), git, curl. Downloads Scala 2.12.18 from GitHub releases and
# clones SpinalHDL v1.13.0, VexRiscv (master @ baf7dc8) and scopt v4.1.0, then compiles
# them with plain scalac. commons-io and OpenHFT affinity are replaced by the two small
# stand-ins in this folder (FileUtils.java, Affinity.java), which is enough for Verilog
# generation (not for SpinalSim).
#
# Usage: sh build_offline.sh <work dir>     (output: <work dir>/rtl/VexRiscv.v)
# Environment for the generator: ICACHE_KB, DCACHE_KB, CACHE_WAYS, FPU (0/1/2), DBUS_WIDTH.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:?usage: build_offline.sh <work dir>}
mkdir -p "$W" && cd "$W"
[ -d scala-2.12.18 ] || { curl -sL -o scala.tgz https://github.com/scala/scala/releases/download/v2.12.18/scala-2.12.18.tgz && tar xzf scala.tgz; }
[ -d SpinalHDL ] || git clone -q --depth 1 --branch v1.13.0 https://github.com/SpinalHDL/SpinalHDL
[ -d VexRiscv ] || { git clone -q https://github.com/SpinalHDL/VexRiscv && git -C VexRiscv checkout -q baf7dc82f855eddaf5b0a20a6802c526f127e38a; }
[ -d scopt ] || git clone -q --depth 1 --branch v4.1.0 https://github.com/scopt/scopt
export PATH="$PWD/scala-2.12.18/bin:$PATH"
SC="scalac -nowarn -J-Xmx3g -J-Xss32m -language:reflectiveCalls"
mkdir -p out/payload out/plugin out/scopt out/cio out/sim out/core out/lib out/vex gen wsim
$SC -d out/payload SpinalHDL/idslpayload/src/main/scala/spinal/idslplugin/*.scala
$SC -cp out/payload:scala-2.12.18/lib/scala-compiler.jar -d out/plugin $(find SpinalHDL/idslplugin/src/main -name '*.scala')
cp SpinalHDL/idslplugin/src/main/resources/scalac-plugin.xml out/plugin/
cp -r out/payload/* out/plugin/
(cd out/plugin && jar cf ../idslplugin.jar .)
$SC -d out/scopt scopt/shared/src/main/scala-2.12/scopt/Seq.scala scopt/shared/src/main/scala/scopt/*.scala scopt/jvm/src/main/scala/PlatformReadInstances.scala
javac -d out/cio "$HERE/FileUtils.java" "$HERE/Affinity.java"
# SpinalHDL sim module, minus the OSHI dependency
rm -rf wsim/* && cp -r SpinalHDL/sim/src/main/scala SpinalHDL/sim/src/main/java wsim/
sed -i '/import net.openhft.affinity.impl.VanillaCpuLayout/d' wsim/scala/spinal/sim/VerilatorBackend.scala
sed -i 's/val systemInfo = new oshi.SystemInfo/throw new Exception()/; s/systemInfo.getHardware.getProcessor.getLogicalProcessorCount//' wsim/scala/spinal/sim/SimManager.scala
$SC -cp out/cio:out/scopt -d out/sim $(find wsim -name '*.scala') $(find wsim -name '*.java')
javac -nowarn -d out/sim -cp out/sim:out/cio:scala-2.12.18/lib/scala-library.jar $(find wsim -name '*.java')
printf 'package spinal.core\nobject Info {\n  val version = "1.13.0"\n  val name = "SpinalHDL-core"\n  val gitHash = "v1.13.0"\n}\n' > gen/Info.scala
CP=out/cio:out/scopt:out/sim:out/payload
J=$(find SpinalHDL/core/src/main/java -name '*.java')
$SC -Xplugin:out/idslplugin.jar -cp $CP -d out/core gen/Info.scala $(find SpinalHDL/core/src/main/scala -name '*.scala') $J
javac -nowarn -d out/core -cp out/core:scala-2.12.18/lib/scala-library.jar $J
$SC -Xplugin:out/idslplugin.jar -cp $CP:out/core -d out/lib $(find SpinalHDL/lib/src/main/scala -name '*.scala' | grep -v "MultithreadedTester\|DualSimTracer")
V=VexRiscv/src/main/scala/vexriscv
sed '/new YamlPlugin("cpu0.yaml")/d' $V/demo/GenFull.scala > gen/GenFull.scala
$SC -Xplugin:out/idslplugin.jar -cp $CP:out/core:out/lib -d out/vex $V/Pipeline.scala $V/Riscv.scala $V/Services.scala \
    $V/Stage.scala $V/VexRiscv.scala $(ls $V/plugin/*.scala | grep -v Yaml) $V/ip/*.scala $V/ip/fpu/*.scala \
    gen/GenFull.scala "$HERE/GenUfo50Cpu.scala"
mkdir -p rtl
OUT=rtl java -Xmx3g -Xss32m -cp $CP:out/core:out/lib:out/vex:scala-2.12.18/lib/scala-library.jar:scala-2.12.18/lib/scala-reflect.jar \
    vexriscv.demo.GenUfo50Cpu
echo "generated $W/rtl/VexRiscv.v"
