import os

def patch_nt36xxx():
    kernel_root = os.getcwd()
    dirs = [
        os.path.join(kernel_root, "drivers/input/touchscreen/nt36xxx"),
        os.path.join(kernel_root, "drivers/input/touchscreen/nt36525b_spi")
    ]

    for d in dirs:
        if not os.path.exists(d):
            continue

        # 1. Enable ESD Protect & Auto-Recovery in header
        h_file = os.path.join(d, "nt36xxx.h")
        if os.path.exists(h_file):
            with open(h_file, "r") as f:
                content = f.read()
            if "#define NVT_TOUCH_ESD_PROTECT 0" in content:
                content = content.replace("#define NVT_TOUCH_ESD_PROTECT 0", "#define NVT_TOUCH_ESD_PROTECT 1")
                with open(h_file, "w") as f:
                    f.write(content)
                print(f"[+] Enabled NVT_TOUCH_ESD_PROTECT in {h_file}")

        # 2. Filter zero-area / zero-pressure phantom ghost touches in C source
        c_file = os.path.join(d, "nt36xxx.c")
        if os.path.exists(c_file):
            with open(c_file, "r") as f:
                c_content = f.read()

            target = "input_w = (uint32_t)(point_data[position + 4]);"
            replacement = (
                "/* Filter electrical noise & bezel stray capacitance */\n"
                "\t\t\tif (point_data[position + 4] == 0 && point_data[position + 5] == 0)\n"
                "\t\t\t\tcontinue;\n"
                "\t\t\tinput_w = (uint32_t)(point_data[position + 4]);"
            )

            if target in c_content and "Filter electrical noise" not in c_content:
                c_content = c_content.replace(target, replacement, 1)
                with open(c_file, "w") as f:
                    f.write(c_content)
                print(f"[+] Injected zero-width/zero-pressure ghost touch filter in {c_file}")

if __name__ == "__main__":
    patch_nt36xxx()
