global so_emul

section .bss

; Tablica stanów rdzeni procesora. Każde 8 bitów reprezentuje stan pewnego rdzenia.
cpu_state: resq CORES

; Semafor służący do zapewnienia atomowości instrukcji XCHG, implementacja spinlocka.
semaphore: resd 1

section .rodata

; Tablica skoków dla instrukcji dwuargumentowych (MOV, OR, ADD, SUB, ADC, SBB).
jump_table_two_arguments:
        dq execute_instruction.mov - jump_table_two_arguments,
        dq execute_instruction.exit - jump_table_two_arguments,
        dq execute_instruction.or - jump_table_two_arguments,
        dq execute_instruction.exit - jump_table_two_arguments,
        dq execute_instruction.add - jump_table_two_arguments,
        dq execute_instruction.sub - jump_table_two_arguments,
        dq execute_instruction.adc - jump_table_two_arguments,
        dq execute_instruction.sbb - jump_table_two_arguments

; Tablica skoków dla instrukcji z jednym argumentem (MOVI, XORI, ADDI, CMPI, RCR).
jump_table_one_argument:
        dq execute_instruction.movi - jump_table_one_argument,
        dq execute_instruction.exit - jump_table_one_argument,
        dq execute_instruction.exit - jump_table_one_argument,
        dq execute_instruction.xori - jump_table_one_argument,
        dq execute_instruction.addi - jump_table_one_argument,
        dq execute_instruction.cmpi - jump_table_one_argument,
        dq execute_instruction.rcr - jump_table_one_argument,
        dq execute_instruction.exit - jump_table_one_argument

; Tablica skoków dla instrukcji skoków (JMP, JNC, JC, JNZ, JZ).
jumptable_jump:
        dq execute_instruction.jmp - jumptable_jump,
        dq execute_instruction.exit - jumptable_jump,
        dq execute_instruction.jnc - jumptable_jump,
        dq execute_instruction.jc - jumptable_jump,
        dq execute_instruction.jnz - jumptable_jump,
        dq execute_instruction.jz - jumptable_jump,
        dq execute_instruction.exit - jumptable_jump,
        dq execute_instruction.exit - jumptable_jump

section .text

; Funkcja wpisująca adres odpowiedniego argumentu do rejestru R9.
; Rozmieszczenie zmiennych w rejestrach (w momencie wywołania funkcji load_argument):
; RSI       -> wskaźnik na dane (data)
; RAX       -> adres stanu rdzenia o numerze core
; [RAX]     -> adres rejestru A
; [RAX + 1] -> adres rejestru D
; [RAX + 2] -> adres rejestru X
; [RAX + 3] -> adres rejestru Y
; RCX       -> trzy najmniej znaczące bity to liczba z zakresu [0, 7] (identyfikator argumentu)
; W trakcie wykonywania funkcji rejestr RCX może zostać zmodyfikowany.
; Wynik:
; R9        -> adres odpowiedniego argumentu, w zależności od identyfikatoru argumentu:
; Dla wartości 0, 1, 2, 3: adres rejestru odpowiednio A, D, X, Y
; Dla wartości 4, 5: adres komórki pamięci danych o adresie w rejestrze odpowiednio X, Y
; Dla wartości 6, 7: adres komórki pamięci danych o adresie będącym sumą wartości rejestrów
; odpowiednio X i D, Y i D
load_argument:
        and     rcx, 0x7                           ; Zerujemy rejestr RCX, poza trzema najmniej znaczącymi
                                                   ; bitami.
        lea     r9, [rax + rcx]                    ; R9 := adres [RAX + RCX].
        cmp     cl, 3                              ; Jeśli CL <= 3, w R9 jest już poprawny adres i możemy
        jle     .exit                              ; wrócić.
                                                   ; Jeśli CL > 3, oznacza to, że musimy znaleźć adres
                                                   ; odpowiedniej komórki pamięci danych. Dla wartości
                                                   ; CL <= 5 należy odjąć od R9 liczbę 2 (wtedy w R9 będzie
                                                   ; odpowiednio [RAX + 2] lub [RAX + 3]), natomiast dla
                                                   ; wartości CL > 5, należy odjąć od R9 liczbę 4.
        sub     r9, 2                              ; R9 -= 2.
        cmp     cl, 5                              ; Jeśli CL > 5, wynikowy adres jest sumą wartości
        jg      .load_d                            ; rejestrów X i D lub Y i D.
        movzx   r9, byte [r9]                      ; R9 := wartość pod adresem w rejestrze R9.
        jmp     .load_data
.load_d:                                           ; Do wynikowego adresu należy dodać wartość rejestru D.
        sub     r9, 2                              ; R9 -= 2.
        movzx   r9, byte [r9]                      ; R9 := wartość pod adresem w rejestrze R9.
        add     r9b, byte [rax + 1]                ; R9 += wartość w rejestrze D.
.load_data:
        add     r9, rsi                            ; R9 += adres danych (data).
.exit:
        ret

; Funkcja ustawiająca wartość flagi carry na równą wartości flagi C w stanie rdzenia o numerze core.
; Rozmieszczenie zmiennych w rejestrach (w momencie wywołania funkcji load_carry_flag):
; RAX       -> adres stanu rdzenia o numerze core
; [RAX + 6] -> adres flagi C (carry)
load_carry_flag:
        clc                                        ; Zerujemy flagę carry.
        cmp     byte [rax + 6], 0                  ; Jeśli wartość flagi C w stanie rdzenia o numerze
        je      .exit                              ; core wynosi zero, wracamy.
        stc                                        ; W przeciwnym przypadku ustawiamy flagę carry.
.exit:
        ret

; Funkcja wykonująca instrukcję w rejestrze BX i odpowiednio modyfikująca stan rdzenia.
; Rozmieszczenie zmiennych w rejestrach (w momencie wywołania funkcji execute_instruction):
; RDI       -> wskaźnik na code
; RSI       -> wskaźnik na dane (data)
; RDX       -> ile kroków, kolejnych instrukcji (włącznie z aktualną), ma wykonać emulator
; RAX       -> wskaźnik na cpu_state rdzenia o numerze core
; [RAX]     -> wskaźnik na rejestr A
; [RAX + 1] -> wskaźnik na rejestr D
; [RAX + 2] -> wskaźnik na rejestr X
; [RAX + 3] -> wskaźnik na rejestr Y
; [RAX + 4] -> wskaźnik na licznik PC
; [RAX + 6] -> wskaźnik na flagę C (carry)
; [RAX + 7] -> wskaźnik na flagę Z (zero)
; RBX       -> aktualna instrukcja ( code[PC] ), zero-extended
; W trakcie wykonywania funkcji rejestry RBX i RDX mogą zostać zmodyfikowane.
execute_instruction:
        inc     byte [rax + 4]                     ; PC++.
        cmp     bx, 0xffff                         ; Jeśli BX == 0xFFFF, wykonujemy instrukcję BRK.
        je      .brk

        mov     r10b, bl                           ; R10B := BL.

        cmp     bh, 0xc6                           ; Jeśli BH >= 0xC6, aktualna instrukcja jest niepoprawna.
        jae      .exit

        cmp     bh, 0xc0                           ; Jeśli 0xC6 > BH >= 0xC0, aktualna instrukcja jest
        jae     .type_jump                         ; instrukcją skoku. W R10B mamy wartość 8-bitowej stałej
                                                   ; imm8.

        cmp     bh, 0x80                           ; Jeśli 0xC0 > BH >= 0x80, aktualna instrukcja jest
        jae     .type_carry_flag                   ; instrukcją modyfikującą flagę C.

        lea     rcx, [rbx]                         ; RCX := RBX, żeby nie modyfikować RBX.

        shr     cx, 8                              ; CL := CH.
        push    rcx                                ; Wrzucamy na stos RCX, żeby w razie potrzeby móc
                                                   ; odkodować też adres drugiego argumentu.
        call    load_argument                      ; R9 := adres pierwszego argumentu.
        cmp     bh, 0x40                           ; Jeśli 0x80 > BH >= 0x40, aktualna instrukcja jest
        jae     .type_one_argument                 ; instrukcją z jednym argumentem. W R9 jest adres tego
                                                   ; argumentu, a w R10B jest wartość 8-bitowej stałej imm8.

        pop     rcx                                ; Przywracamy ze stosu wartość RCX.
        push    r9                                 ; Wrzucamy na stos R9, ponieważ zaraz zostanie nadpisany
                                                   ; przez adres drugiego argumentu.
        shr     cl, 3                              ; Przesuwamy CL o 3 bity w lewo, teraz 3 najmniej znaczące
                                                   ; bity to identyfikator drugiego argumentu.
        call    load_argument                      ; R9 := adres drugiego argumentu.
        lea     r11, [r9]                          ; R11 := R9.
        mov     r10b, byte [r9]                    ; R10B := wartość pod adresem w rejestrze R9.
        pop     r9                                 ; Przywracamy ze stosu wartość R9, teraz znowu
                                                   ; R9 := adres pierwszego argumentu.

.type_two_arguments:                               ; Instrukcja dwuargumentowa. R9 := adres pierwszego,
                                                   ; argumentu R10B := wartość drugiego argumentu,
                                                   ; R11 := adres drugiego argumentu.
        and     bx, 0xf                            ; Zerujemy rejestr BX, poza czterema najmniej znaczącymi
                                                   ; bitami.
        lea     r8, [rel jump_table_two_arguments] ; R8 := adres tablicy skoków dla instrukcji
                                                   ; dwuargumentowych.

        cmp     bl, 8
        je      .xchg                              ; Jeśli BL == 8, aktualna instrukcja to XCHG.
        jg      .exit                              ; Jeśli BL > 8, aktualna instrukcja jest niepoprawna.

.use_jump_table:                                   ; Funkcja korzystająca z tablicy skoków, której adres
                                                   ; znajduje się w rejestrze R8. W rejestrze RBX znajduje
                                                   ; się indeks labela, do którego należy skoczyć.
                                                   ; R8 := jump_table, RBX := i,
                                                   ; Skaczemy do adresu jump_table[i].
        mov     rbx, [r8 + 8 * rbx]                ; RB := adres labela, do którego trzeba skoczyć.
        add     rbx, r8                            ; RBX += R8 (w deklaracji tablicy skoków od każdego
        jmp     rbx                                ; argumentu jest odjęte R8).

.mov:                                              ; Instrukcja MOV.
        mov     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu := wartość
        ret                                        ; drugiego argumentu.

.or:                                               ; Instrukajca OR.
        or      byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu |= wartość
        jmp     .set_zero_flag                     ; drugiego argumentu. Modyfikujemy flagę Z.

.add:                                              ; Instrukcja ADD.
        add     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu += wartość
        jmp     .set_zero_flag                     ; drugiego argumentu. Modyfikujemy flagę Z.

.sub:                                              ; Instrukcja SUB.
        sub     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu -= wartość
        jmp     .set_zero_flag                     ; drugiego argumentu. Modyfikujemy flagę Z.

.adc:                                              ; Instrukcja ADC.
        call    load_carry_flag                    ; Ładujemy wartość flagi C.
        adc     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu += wartość
        setc    byte [rax + 6]                     ; drugiego argumentu + wartość flagi C.
        jmp     .set_zero_flag                     ; Modyfikujemy flagi C i Z.

.sbb:                                              ; Instrukcja SBB.
        call    load_carry_flag                    ; Ładujemy wartość flagi C.
        sbb     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu -= wartość
        setc    byte [rax + 6]                     ; drugiego argumentu - wartość flagi C.
        jmp     .set_zero_flag                     ; Modyfikujemy flagi C i Z.

.xchg:                                             ; Instrukcja XCHG.
        mov     cx, 1                              ; CX := 1.
.loop:
        lock xchg [rel semaphore], cx              ; Synchronizacja realizowana za pomocą spinlocka
        test    cx, cx                             ; (z labów), z wykorzystaniem zmiennej semaphore.
        jne     .loop

        xchg    byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu :=: wartość
                                                   ; drugiego argumentu.
        xchg    byte [r11], r10b                   ; Wartość pod adresem drugiego argumentu :=: wartość
                                                   ; pierwszego argumentu.

        mov     dword [rel semaphore], 0           ; Zerujemy (otwieramy) spinlocka.
        ret

.type_one_argument:                                ; Instrukcja jednoargumentowa. R9 := adres pierwszego
                                                   ; argumentu, R10B := wartość 8-bitowej stałej imm8.
        pop     rcx                                ; Zdejmujemy zapisaną wartość ze stosu (nie jest już nam
                                                   ; potrzebna).
        shr     bx, 0xb                            ; Przesuwamy BX w prawo o 11 bitów.
        and     bl, 0x7                            ; Zerujemy rejestr BX, poza trzema najmniej znaczącymi
                                                   ; bitami.
        lea     r8, [rel jump_table_one_argument]  ; R8 := adres tablicy skoków dla instrukcji
                                                   ; jednoargumentowych.
        jmp     .use_jump_table                    ; Korzystamy z tablicy skoków.

.movi:                                             ; Instrukcja MOVI.
        mov     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu := wartość
        ret                                        ; 8-bitowej stałej imm8.

.xori:                                             ; Instrukcja XORI.
        xor     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu ^= wartość
        jmp     .set_zero_flag                     ; 8-bitowej stałej imm8. Modyfikujemy flagę Z.

.addi:                                             ; Instrukcja ADDI.
        add     byte [r9], r10b                    ; Wartość pod adresem pierwszego argumentu += wartość
        jmp     .set_zero_flag                     ; 8-bitowej stałej imm8. Modyfikujemy flagę Z.

.cmpi:                                             ; Instrukcja CMPI.
        cmp     byte [r9], r10b                    ; Porównujemy wartość pod adresem pierwszego argumentu z
        setc    byte [rax + 6]                     ; wartością 8-bitowej stałej imm8.
        jmp     .set_zero_flag                     ; Modyfikujemy flagi C i Z.

.rcr:                                              ; Instrukcja RCR.
        call    load_carry_flag                    ; Ładujemy wartość flagi C.
        rcr     byte [r9], 1                       ; Rotujemy wartość pod adresem pierwszego argumentu.
        setc    byte [rax + 6]                     ; Modyfikujemy flagę C.
        ret

.type_carry_flag:                                  ; Instrukcja modyfikująca flagę C.
        cmp     bx, 0x8000                         ; Jeśli BX == 0x8000, aktualna instrukcja to CLC.
        je      .clc
        cmp     bx, 0x8100                         ; Jeśli BX == 0x8100, aktualna instrukcja to STC.
        je      .stc
        ret                                        ; W przeciwnym przypadku instrukcja nie jest poprawna.

.clc:                                              ; Instrukcja CLC.
        mov     byte [rax + 6], 0                  ; Flaga C := 0.
        ret

.stc:                                              ; Instrukcja STC.
        mov     byte [rax + 6], 1                  ; Flaga C := 1.
        ret

.type_jump:                                        ; Instrukcja skoku. R10B := 8-bitowa stała imm8.
        shr     bx, 8                              ; BL := BH.
        and     bl, 0x7                            ; Zerujemy rejestr BX, poza trzema najmniej znaczącymi
                                                   ; bitami.
        lea     r8, [rel jumptable_jump]           ; R8 := adres tablicy skoków dla instrukcji skoków.
        jmp     .use_jump_table                    ; Korzystamy z tablicy skoków.

.jmp:                                              ; Instrukcja JMP.
        jmp     .execute_jump

.jnc:                                              ; Instrukcja JNC.
        cmp     byte [rax + 6], 0                  ; Jeśli flaga C jest ustawiona na 0, wykonujemy skok.
        je      .execute_jump
        ret

.jc:                                               ; Instrukcja JC.
        cmp     byte [rax + 6], 1                  ; Jeśli flaga 1 jest ustawiona na 0, wykonujemy skok.
        je      .execute_jump
        ret

.jnz:                                              ; Instrukcja JNZ.
        cmp     byte [rax + 7], 0                  ; Jeśli flaga Z jest ustawiona na 0, wykonujemy skok.
        je      .execute_jump
        ret

.jz:                                               ; Instrukcja JZ.
        cmp     byte [rax + 7], 1                  ; Jeśli flaga Z jest ustawiona na 1, wykonujemy skok.
        je      .execute_jump
        ret

.execute_jump:                                     ; Funkcja wykonująca instrukcję skoku.
        add     [rax + 4], r10b                    ; PC += wartość 8-bitowej stałej imm8.
        ret

.brk:                                              ; Instrukcja BRK.
        mov     rdx, 1                             ; Żeby program zakończył działanie, możemy ustawić wartość
        ret                                        ; zmiennej cores := 1. Oznacza to, że włącznie z aktualnie
                                                   ; wykonywaną instrukcją, emulator ma wykonać jedną
                                                   ; instrukcję (czyli obecna instrukcja jest ostatnią).

.set_zero_flag:                                    ; Funkcja modyfikująca flagę Z.
        setz    byte [rax + 7]
        ret

.exit:
        ret

; Rozmieszczenie zmiennych w rejestrach (w momencie wywołania funkcji so_emul):
; RDI       -> wskaźnik na code
; RSI       -> wskaźnik na data
; RDX       -> steps
; RCX       -> core
; W trakcie wykonywania funkcji rejestry RDX i RCX mogą zostać zmodyfikowane, w szczególności wartość w
; rejestrze RDX będzie mówić, ile kroków, kolejnych instrukcji (włącznie z aktualną), ma wykonać emulator.
so_emul:
        push    rbx                                ; W celu zachowania rejestru RBX.
        lea     rax, [rel cpu_state]               ; RAX := adres zmiennej cpu_state (tablicy stanów).
        jrcxz   .after_loop_move_pointer           ; Jeśli core == 0, nie trzeba modyfikować adresu.

.loop_move_pointer:                                ; W przeciwnym przypadku należy dodać do adresu tablicy
        add     rax, 64                            ; stanów wartość core * 64 bity (RAX += core * 64).
        loop    .loop_move_pointer                 ; Dopóki RCX != 0, wykonujemy operacje RAX += 64, RCX--.

.after_loop_move_pointer:                          ; Teraz RAX: adres stanu rdzenia o numerze core.
        test    rdx, rdx                           ; Jeśli steps == 0, kończymy działanie programu.
        jz      .exit

.loop:                                             ; Główna pętla, w jednym obrocie jest wykonywana jedna
                                                   ; instrukcja.
        movzx   rbx, byte [rax + 4]                ; RBX := PC, zero-extended.
        movzx   rbx, word [rdi + 2 * rbx]          ; RBX := code[PC], zero-extended (wskaźnik na code,
                                                   ; przesunięty o 2 * PC bajtów).
                                                   ; (Każda instrukcja zajmuje 2 bajty).
        call    execute_instruction                ; Wywołujemy funkcję wykonującą daną instrukcję.
        dec     rdx                                ; Zmniejszamy steps--;
        test    rdx, rdx                           ; Jeśli steps == 0, kończymy działanie programu.
        jnz     .loop                              ; W przeciwnym przypadku znowu wykonujemy pętlę.

.exit:                                             ; Funkcja kończąca działanie programu.
        mov     rax, [rax]                         ; RAX := wartość pod adresem w rejestrze RAX.
        pop     rbx                                ; Przywracamy RBX.
        ret                                        ; Wracamy.
