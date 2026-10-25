package org.apache.commons.io;
import java.io.*; import java.nio.file.*; import java.util.*;
/* Minimal stand-in for commons-io FileUtils: only what SpinalHDL's Verilog generation touches.
   Built here because Maven Central is unreachable from the build container. */
public class FileUtils {
  public static void forceMkdir(File d) throws IOException { Files.createDirectories(d.toPath()); }
  public static void forceMkdirParent(File f) throws IOException { File p = f.getAbsoluteFile().getParentFile(); if (p != null) forceMkdir(p); }
  public static void cleanDirectory(File d) throws IOException { File[] l = d.listFiles(); if (l!=null) for (File f: l) deleteQuietly(f); }
  public static void deleteDirectory(File d) throws IOException { if (!d.exists()) return; cleanDirectory(d); d.delete(); }
  public static boolean deleteQuietly(File f) { try { if (f.isDirectory()) deleteDirectory(f); else f.delete(); return true; } catch (Exception e) { return false; } }
  public static void copyFileToDirectory(File f, File d) throws IOException { forceMkdir(d); copyFile(f, new File(d, f.getName())); }
  public static void copyFile(File a, File b) throws IOException { forceMkdirParent(b); Files.copy(a.toPath(), b.toPath(), StandardCopyOption.REPLACE_EXISTING); }
  public static void copyDirectory(File a, File b) throws IOException { copyDirectory(a, b, null); }
  public static void copyDirectory(File a, File b, FileFilter ff) throws IOException { forceMkdir(b); File[] l = a.listFiles(); if (l!=null) for (File f: l) { if (ff!=null && !ff.accept(f)) continue; if (f.isDirectory()) copyDirectory(f, new File(b, f.getName()), ff); else copyFile(f, new File(b, f.getName())); } }
  public static Collection<File> listFiles(File d, String[] ext, boolean rec) { List<File> r = new ArrayList<>(); File[] l = d.listFiles(); if (l!=null) for (File f: l) { if (f.isDirectory()) { if (rec) r.addAll(listFiles(f, ext, rec)); } else r.add(f); } return r; }
  public static void touch(File f) throws IOException { if (!f.exists()) new FileOutputStream(f).close(); f.setLastModified(System.currentTimeMillis()); }
  public static void writeStringToFile(File f, String s, String cs) throws IOException { Files.write(f.toPath(), s.getBytes(cs)); }
  public static String readFileToString(File f, String cs) throws IOException { return new String(Files.readAllBytes(f.toPath()), cs); }
}
