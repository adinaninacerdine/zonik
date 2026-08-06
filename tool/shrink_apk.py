"""Réduit un APK release : strip des bibliothèques natives puis re-signature.

Le NDK (~4 Go) ne tient pas sur le disque, donc Gradle ne peut pas stripper
libflutter.so (150 Mo de symboles de debug -> ~8 Mo strippé). Ce script fait
l'opération à la main avec un llvm-strip récupéré seul (~2 Mo).

Usage : python tool/shrink_apk.py <apk_entrée> <apk_sortie>
Prérequis : C:\\Dev\\tools\\llvm-strip\\llvm-strip.exe, android/key.properties.
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

LLVM_STRIP = r"C:\Dev\tools\llvm-strip\llvm-strip.exe"
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def build_tools():
    root = os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\build-tools")
    return sorted(glob.glob(os.path.join(root, "*")))[-1]


def key_properties():
    props = {}
    with open(os.path.join(PROJECT, "android", "key.properties"), encoding="utf-8") as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                props[k] = v
    return props


def main(src, dest):
    bt = build_tools()
    props = key_properties()
    keystore = os.path.normpath(os.path.join(PROJECT, "android", "app", props["storeFile"]))

    with tempfile.TemporaryDirectory() as tmp:
        extracted = os.path.join(tmp, "apk")
        with zipfile.ZipFile(src) as z:
            infos = z.infolist()
            z.extractall(extracted)

        # 1. Strip de toutes les bibliothèques natives.
        for info in infos:
            if info.filename.endswith(".so"):
                path = os.path.join(extracted, info.filename.replace("/", os.sep))
                before = os.path.getsize(path)
                subprocess.run([LLVM_STRIP, "--strip-all", path], check=True)
                after = os.path.getsize(path)
                print(f"strip {info.filename}: {before // 1024 // 1024} Mo -> "
                      f"{after // 1024 // 1024} Mo")

        # 2. Rezip en respectant la compression d'origine de chaque entrée
        #    (les .so et resources.arsc doivent rester STORED pour Android).
        unaligned = os.path.join(tmp, "unaligned.apk")
        with zipfile.ZipFile(unaligned, "w") as out:
            for info in infos:
                if info.filename.startswith("META-INF/") and info.filename.endswith(
                        (".SF", ".RSA", ".EC", ".MF")):
                    continue  # ancienne signature, apksigner va re-signer
                path = os.path.join(extracted, info.filename.replace("/", os.sep))
                if os.path.isdir(path):
                    continue
                out.write(path, info.filename, compress_type=info.compress_type)

        # 3. Alignement (pages 4 Kio pour les .so) puis signature v2/v3.
        aligned = os.path.join(tmp, "aligned.apk")
        subprocess.run([os.path.join(bt, "zipalign.exe"), "-f", "-p", "4",
                        unaligned, aligned], check=True)
        subprocess.run([os.path.join(bt, "apksigner.bat"), "sign",
                        "--ks", keystore,
                        "--ks-key-alias", props["keyAlias"],
                        "--ks-pass", "pass:" + props["storePassword"],
                        "--key-pass", "pass:" + props["keyPassword"],
                        "--out", dest, aligned], check=True)
        subprocess.run([os.path.join(bt, "apksigner.bat"), "verify", dest], check=True)

    print(f"OK : {dest} ({os.path.getsize(dest) // 1024 // 1024} Mo)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
