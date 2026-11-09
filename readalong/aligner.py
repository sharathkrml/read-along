"""Read Along — speech-to-script alignment.

Aligns live ASR words to the script, snapping to nearby lines when the reader
restarts or skips, and advancing monotonically otherwise. Only exact word
matches move the cursor, so ASR errors and OCR mistakes do not throw it off.
"""

from __future__ import annotations

import bisect
import difflib
from functools import lru_cache


class Aligner:
    """Aligns live ASR words to the script, snapping to nearby lines when the
    reader restarts or skips, and advancing monotonically otherwise."""

    def __init__(self, words: list[str]):
        self.words = words
        self.pos = 0
        self.conf = 0.0
        # Last word matched exactly in the current utterance, even when the
        # cursor cannot commit yet. The UI draws this as a live "heard" cue.
        self.heard = -1
        self._index: dict[str, list[int]] = {}
        for i, w in enumerate(words):
            self._index.setdefault(w, []).append(i)

    @staticmethod
    @lru_cache(maxsize=4096)
    def _score(a: str, b: str) -> float:
        if a == b:
            return 1.0
        if difflib.SequenceMatcher(None, a, b).ratio() >= 0.62:
            return 0.3
        return -0.4

    def _find(self, word: str, start: int) -> int:
        """First exact occurrence of word in [start, start+4), or -1."""
        pos = self._index.get(word)
        if not pos:
            return -1
        i = bisect.bisect_left(pos, start)
        if i < len(pos) and pos[i] < start + 4:
            return pos[i]
        return -1

    def _anchor(self, asr: list[str], final: bool):
        """Find the best nearby start for the spoken phrase.

        Returns (score, end_position, exact_words) or None. This is what lets a
        reader restart a line just above the cursor, or skip a paragraph and
        start a line just below it, without clicking.
        """
        n = len(asr)
        if n < 3:
            return None
        back = 400
        ahead = 400
        min_exact = 4
        lo = max(0, self.pos - back)
        hi = min(len(self.words), self.pos + ahead)
        if hi - lo < n:
            return None
        best = None
        words = self.words
        nwords = len(words)
        first = asr[0]
        for start in range(lo, hi):
            j = start
            exact = 0
            matched = 0
            last = -1
            found = self._find(first, j)
            if found >= 0:
                exact += 1
                matched += 1
                last = found
                j = found + 1
            elif j < nwords and self._score(first, words[j]) > 0:
                matched += 1
                j += 1
            else:
                continue
            for a in asr[1:]:
                found = self._find(a, j)
                if found >= 0:
                    exact += 1
                    matched += 1
                    last = found
                    j = found + 1
                elif j < nwords and self._score(a, words[j]) > 0:
                    matched += 1
                    j += 1
            if exact < min_exact:
                continue
            score = exact - 0.6 * (n - matched) - 0.005 * abs(start - self.pos)
            if best is None or score > best[0]:
                best = (score, j, exact, last)
        return best

    def update(self, text: str, final: bool = False) -> int:
        from .text_model import norm_token

        asr = [norm_token(t) for t in text.split()]
        asr = [t for t in asr if t][-14:]
        if not asr:
            return self.pos

        # A nearby line wins immediately, in either direction. This is the
        # "I messed up, let me start this line again" and "skip ahead a bit"
        # path; the monotonic DP below handles normal reading.
        anchor = self._anchor(asr, final)
        if anchor:
            score, end, exact, last = anchor
            if abs(end - self.pos) >= 2 and score >= 2.0:
                self.pos = max(0, min(len(self.words), end))
                self.conf = min(1.0, exact / max(1, len(asr)))
                if last >= 0:
                    self.heard = last
                return self.pos

        lo = max(0, self.pos - 3)
        hi = len(self.words) if final else min(len(self.words), self.pos + 32)
        if hi <= lo:
            return self.pos
        script = self.words[lo:hi]
        n, m = len(asr), len(script)
        neg = -1e9
        dp = [[neg] * (m + 1) for _ in range(n + 1)]
        dp[0][0] = 0.0
        for j in range(1, m + 1):
            dp[0][j] = dp[0][j - 1] - 0.10
        for i in range(1, n + 1):
            dp[i][0] = dp[i - 1][0] - 0.50
        for i in range(1, n + 1):
            for j in range(1, m + 1):
                sc = self._score(asr[i - 1], script[j - 1])
                dp[i][j] = max(dp[i - 1][j - 1] + sc, dp[i][j - 1] - 0.10, dp[i - 1][j] - 0.50)
        best_j, best = 0, neg
        for j in range(1, m + 1):
            if dp[n][j] > best:
                best, best_j = dp[n][j], j
        if best_j == 0:
            return self.pos
        conf = best / max(1, n)
        self.conf = max(0.0, min(1.0, conf))

        # Only advance to the last *exact* match in the alignment. A fuzzy
        # substitution is enough to keep reading, but not enough to move the
        # cursor past a word the reader may not have said yet.
        i, j, last_exact = n, best_j, -1
        while i > 0 and j > 0:
            sc = self._score(asr[i - 1], script[j - 1])
            if abs(dp[i][j] - (dp[i - 1][j - 1] + sc)) < 1e-9:
                if sc >= 1.0:
                    last_exact = j - 1
                    break
                i -= 1
                j -= 1
            elif abs(dp[i][j] - (dp[i][j - 1] - 0.10)) < 1e-9:
                j -= 1
            else:
                i -= 1
        if last_exact < 0:
            return self.pos
        # The cue is a liveness signal, not a second cursor. Keep it near the
        # cursor: one word can match a common word far ahead, and a dot in a
        # different paragraph reads as a glitch instead of "I heard you".
        heard = lo + last_exact
        if heard <= self.pos + 8:
            self.heard = heard

        new_pos = min(len(self.words), lo + last_exact + 1)
        if new_pos <= self.pos:
            return self.pos
        if not final and n < 2:
            return self.pos
        if conf < (0.25 if final else 0.15):
            return self.pos
        if not final and new_pos - self.pos > 8:
            return self.pos
        if final and new_pos - self.pos > 6 and n < 3:
            return self.pos
        self.pos = new_pos
        return self.pos
