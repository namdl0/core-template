package net.openhft.affinity;
/* No-op stand-in for OpenHFT Java-Thread-Affinity (only used for simulation thread pinning). */
public class Affinity {
  public static void setAffinity(int cpu) {}
  public static void setAffinity(java.util.BitSet s) {}
  public static java.util.BitSet getAffinity() { return new java.util.BitSet(); }
}
