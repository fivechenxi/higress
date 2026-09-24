// Copyright (c) 2026 TokenVolt
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import "github.com/higress-group/wasm-go/pkg/wrapper"

const (
	maxIncompleteSSEEventBytes = 1 * 1024 * 1024 // 1 MiB
	maxSSEDelimiterBytes       = 4               // len("\r\n\r\n")
)

// sseFramer is request-scoped state that converts arbitrary Envoy response
// body callbacks into complete SSE events. It only observes the response: the
// original callback bytes are always returned downstream unchanged.
type sseFramer struct {
	tail          []byte
	resyncing     bool
	resyncCarry   []byte
	overflowCount int
}

// frameCallback emits complete SSE events and retains only the final
// incomplete event. Event boundaries are detected on raw bytes so CRLF
// delimiters split across callbacks are handled correctly.
func (f *sseFramer) frameCallback(chunk []byte) (events [][]byte) {
	if f.resyncing {
		w := byteWindow{a: f.resyncCarry, b: chunk}
		ends := w.scanEventEnds(1)
		if len(ends) == 0 {
			f.resyncCarry = w.lastBytes(0, maxSSEDelimiterBytes-1)
			return nil
		}

		end := ends[0]
		f.resyncing = false
		f.resyncCarry = nil
		f.tail = nil
		if end > len(w.a) {
			chunk = chunk[end-len(w.a):]
		}
	}

	w := byteWindow{a: f.tail, b: chunk}
	ends := w.scanEventEnds(0)
	n := w.len()
	prev := 0
	for _, end := range ends {
		var event []byte
		if prev >= len(f.tail) {
			event = chunk[prev-len(f.tail) : end-len(f.tail)]
		} else {
			event = w.sliceRange(prev, end)
		}
		events = append(events, wrapper.UnifySSEChunk(event))
		prev = end
	}

	switch suffixLen := n - prev; {
	case suffixLen == 0:
		f.tail = nil
	case suffixLen <= maxIncompleteSSEEventBytes:
		f.tail = w.sliceRange(prev, n)
	default:
		f.tail = nil
		f.resyncing = true
		f.resyncCarry = w.lastBytes(prev, maxSSEDelimiterBytes-1)
		f.overflowCount++
	}
	return events
}

// drain returns a final unterminated event, when present, and clears all
// request state. Some OpenAI-compatible providers terminate the connection
// immediately after their final data line without an extra blank line; that
// event is still safe to parse once Envoy reports endOfStream.
func (f *sseFramer) drain() (lastEvent []byte, overflowCount int) {
	if !f.resyncing && len(f.tail) > 0 {
		lastEvent = wrapper.UnifySSEChunk(f.tail)
	}
	f.tail = nil
	f.resyncing = false
	f.resyncCarry = nil
	return lastEvent, f.overflowCount
}

type byteWindow struct {
	a []byte
	b []byte
}

func (w byteWindow) len() int { return len(w.a) + len(w.b) }

func (w byteWindow) at(i int) byte {
	if i < len(w.a) {
		return w.a[i]
	}
	return w.b[i-len(w.a)]
}

func (w byteWindow) lineEndingEnd(i int) (end int, pending bool) {
	if w.at(i) == '\n' {
		return i + 1, false
	}
	if i+1 == w.len() {
		return i, true
	}
	if w.at(i+1) == '\n' {
		return i + 2, false
	}
	return i + 1, false
}

func (w byteWindow) scanEventEnds(limit int) []int {
	var ends []int
	for pos, n := 0, w.len(); pos < n; {
		c := w.at(pos)
		if c != '\n' && c != '\r' {
			pos++
			continue
		}
		firstEnd, pending := w.lineEndingEnd(pos)
		if pending {
			break
		}
		if firstEnd < n {
			if next := w.at(firstEnd); next == '\n' || next == '\r' {
				secondEnd, pending := w.lineEndingEnd(firstEnd)
				if pending {
					break
				}
				ends = append(ends, secondEnd)
				if limit > 0 && len(ends) >= limit {
					return ends
				}
				pos = secondEnd
				continue
			}
		}
		pos = firstEnd
	}
	return ends
}

func (w byteWindow) sliceRange(from, to int) []byte {
	out := make([]byte, 0, to-from)
	if from >= len(w.a) {
		return append(out, w.b[from-len(w.a):to-len(w.a)]...)
	}
	if to <= len(w.a) {
		return append(out, w.a[from:to]...)
	}
	out = append(out, w.a[from:]...)
	return append(out, w.b[:to-len(w.a)]...)
}

func (w byteWindow) lastBytes(from, count int) []byte {
	start := w.len() - count
	if start < from {
		start = from
	}
	return w.sliceRange(start, w.len())
}
