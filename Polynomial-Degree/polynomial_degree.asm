global polynomial_degree
section .text

; Do obliczenia stopnia korzystam ze wskazówki z Moodla. Należy w pętli wykonywać
; operację y[i] := y[i] - y[i + 1] dla i = 0..n-2, i przy każdym przejściu pętli
; zmniejszać n o 1 oraz zwiększać stopień (początkowo ustawiony na -1) o 1.
; Wychodzimy z pętli, gdy n = 0 lub gdy wszystkie wartości y[i] są równe zero.
; Jeśli od początku wszystkie wartości w tablicy y to zera, zwracamy -1.

; Różnice są przechowywane na stosie jako biginty. Każda liczba reprezentowana jest
; jako ciąg 8-bajtowych segmentów. Na każdą liczbę wystarczy zarezerwować (n + 32)
; bity, więc liczba segmentów 8-bajtowych potrzebnych na daną liczbę wynosi:
; length := (n + 32) / 64 ≈ n / 64 + 1

; Można myśleć o tablicy tych różnic jak o tablicy dwuwymiarowej diffs, gdzie
; diffs[i][j] to j-ty segment i-tej liczby, dla i = 0..n-1, j = 0..n-1, przy czym
; segmenty są numerowane od prawej do lewej. Początkowo dla i = 0..n-1:
; diffs[i][0] = y[i], zaś pozostałe segmenty to zera. Stos zapełniamy zaczynając
; od odpowiedniej liczby zerowych segmentów, następnie wrzucamy rozszerzoną do
; 64 bitów liczbę y[n-1], i powtarzamy te czynność, dopóki nie zostanie wrzucona
; liczba y[0]. Zatem na samym dole stosu znajduje się liczba diffs[0][0], nad nią
; jest diffs[0][1], i tak dalej.

; W celu ułatwienia sobie iterowania się po wszystkich segmentach, oznaczmy każdy
; segment indeksem od 0 do (n * length - 1), gdzie dla segmentu diffs[i][j]:
; index := i * length + j

; Należy więc również policzyć łączną liczbę segmentów, która wynosi:
; segments := n * length

; Liczenie nowej różnicy, czyli działanie diffs[i] := diffs[i] - diffs[i + 1],
; dla i = 0..n-2, będzie polegało na odejmowaniu w pętli dla j = 0...length-1:
; diffs[i][j] := diffs[i][j] - diffs[i + 1][j] + overflow,
; gdzie overflow to wartość flagi OF po odjęciu poprzednich segmentów danych
; liczb. Początkowo overflow jest ustawiona na 0.

; Rozmieszczenie zmiennych w rejestrach:
; RSI -> n
; EBX -> degree (wynikowy stopień wielomianu)
; RCX -> length (liczba segmentów na liczbę)
; RDX -> segments (łączna liczba segmentów)
; R8  -> i (iterator po różnicach)
; R9  -> j (iterator po segmentach danej różnicy)
; R10 -> index (iterator po wszystkich segmentach)
; AL  -> overflow (wartość flagi OF przy poprzednim odejmowaniu)
; Rejestr RAX będzie służył jako rejestr pomocniczy.

polynomial_degree:
        push    rbx                          ; W celu zachowania rejestru RBX.
        push    rbp                          ; Zapamiętujemy w RBP, gdzie był wierzchołek stosu, w celu
        mov     rbp, rsp                     ; łatwego zwolnienia zaalokowanego miejsca (trik z Moodla).
        
        mov     ebx, -1                      ; Inicjujemy zmienną degree: EBX := -1.

        mov     rcx, rsi                     ; RCX := n.
        shr     rcx, 6                       ; RCX := n / 64 = n / 2^6
        inc     rcx                          ; Inicjujemy zmienną length: RCX := n / 64 + 1
        ; f :( inc     rcx

        mov     rdx, rsi                     ; RDX := n.
        imul    rdx, rcx                     ; Inicjujemy zmienną segments: RDX := n * length.

        lea     r8, [rsi - 1]                ; Inicjujemy iterator i: R8 := n - 1.

.copy_array:                                 ; Funkcja wypełniająca stos odpowiednimi segmentami.
        lea     r9, [rcx - 1]                ; Inicjujemy iterator j: R9 := length - 1.
        test    r9, r9                       ; Jeśli zmienna j ma wartość zero,
        jz      .push_y                      ; od razu wrzucamy na stos liczbę y[i].

.push_zeros:                                 ; Funkcja uzupełniająca stos zerowymi segmentami.
        push    0                            ; Inicjujemy diffs[i][length - j] := 0.
        dec     r9                           ; Zmniejszamy j--.
        jnz     .push_zeros                  ; Jeśli j > 0, dalej wrzucamy na stos zera.

.push_y:                                     ; Funkcja wrzucająca na stos liczbę y[i].
        movsxd  rax, [rdi + 4 * r8]          ; Rozszerzamy liczbę y[i] do 64 bitów.
        push    rax                          ; Inicjujemy diffs[i][0] := y[i].

        dec     r8                           ; Zmniejszamy i--;
        cmp     r8, 0                        ; Porównujemy i z liczbą 0.
        jge     .copy_array                  ; Jeśli i >= 0, dalej uzupełniamy stos segmentami.

.check_for_zeros:                            ; Funkcja sprawdzająca, czy wszystkie segmenty mają wartość zero.
        lea     r10, [rdx - 1]               ; Inicjujemy zmienną index: RCX := segments - 1.
        cmp     r10, 0                       ; Jeśli index < 0, to oznacza, że łącznie jest zero segmentów,
        jl      .exit                        ; czyli kończymy działanie programu.

.check_segment:                              ; Sprawdza, czy segment o indeksie index ma wartość zero.
        mov     rax, [rsp + 8 * r10]         ; Ustawiamy RAX := diffs[index / length][index % length].
        test    rax, rax                     ; Jeśli dany segment nie ma wartości zero, liczymy nowe różnice
        jnz     .calculate_new_differences   ; (nowe wartości tablicy diffs).

.next_segment:                               ; Funkcja przechodząca do następnego segmentu.
        dec     r10                          ; Zmniejszamy index--.
        cmp     r10, 0                       ; Porównujemy index z liczbą zero.
        jge     .check_segment               ; Jeśli index >= 0, sprawdzamy, czy kolejny segment jest zerowy.
        jl      .exit                        ; Jeśli index < 0, oznacza to, że już przetworzyliśmy wszystkie
                                             ; segmenty i wszystkie miały wartość zerową - kończymy działanie
                                             ; programu.

.calculate_new_differences:                  ; Funkcja licząca nowe różnice - wartości tablicy diffs.
        inc     ebx                          ; Zwiększamy degree++.
        dec     rsi                          ; Zmniejszamy n--, ponieważ otrzymamy jedną różnicę mniej.
        sub     rdx, rcx                     ; Zmniejszamy segments -= length, z tego samego powodu.

        xor     r8, r8                       ; Inicjujemy iterator i: R8 := 0.
        xor     r9, r9                       ; Inicjujemy iterator j: R9 := 0.
        xor     r10, r10                     ; Inicjujemy iterator index: R10 := 0.
        xor     al, al                       ; Inicjujemy zmienną oveflow: AL := 0.

.subtract_numbers:
        add     [rsp + 8 * r10], al          ; Dodajemy diffs[i][j] += overflow (segment o indeksie index).
        lea     rax, [rcx + r10]             ; Ustawiamy RAX := length + index.
        mov     rax, [rsp + 8 * rax]         ; Ustawiamy RAX := diffs[i + 1][j] (segment o indeksie równym wartości RAX).
        sub     [rsp + 8 * r10], rax         ; Odejmujemy diffs[i][j] -= diffs[i + 1][j].
        seto    al                           ; Ustawiamy overflow := OF.

        inc     r9                           ; Zwiększamy j++.
        inc     r10                          ; Zwiększamy index++;
        cmp     r9, rcx                      ; Porównujemy wartość j z length.
        jl      .subtract_numbers            ; Jeśli j < length, dalej odejmujemy kolejne segmenty danych liczb.

.next_numbers:                               ; Funkcja przechodząca do następnych liczb.
        xor     r9, r9                       ; Zerujemy iterator j: R9 := 0.
        xor     al, al                       ; Zerujemy zmienną oveflow: AL := 0.
        inc     r8                           ; Zwiększamy i++.
        cmp     r8, rsi                      ; Porównujemy wartość i z n.
        jl      .subtract_numbers            ; Jeśli i < n, dalej odejmujemy kolejne liczby.
        jge     .check_for_zeros             ; Jeśli i >= n, wszystkie nowe różnice już zostały policzone, możemy
                                             ; sprawdzić, czy wszystkie segmenty mają wartość zero.

.exit:                                       ; Funkcja kończąca działanie programu.
        movsxd  rax, ebx                     ; Rozszerzamy liczbę degree do 64 bitów i inicjujemy RAX := degree.
        leave                                ; Przed zakończeniem programu przywracamy poprzedni wierzchołek stosu.
        pop     rbx                          ; Przywracamy RBX.
        ret                                  ; Wracamy.