/* link.ld -- loader CPU: one RAM at 0 holds code, data and stack (RAM_SIZE from build.sh) */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = RAM_SIZE }

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM
    .data : {
        *(.data .data.* .sdata .sdata.*)
    } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(SIZEOF(.data) == 0, "no initialised writable data allowed (a reset would not restore it)")
    ASSERT(__bss_end + 1536 <= __stack_top, "less than 1.5 KB left for the stack")
}
