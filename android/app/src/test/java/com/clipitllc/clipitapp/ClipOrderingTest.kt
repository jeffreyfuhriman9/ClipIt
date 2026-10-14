package com.clipitllc.clipitapp

import com.clipitllc.clipitapp.ui.Clip
import com.clipitllc.clipitapp.ui.ClipFilter
import com.clipitllc.clipitapp.ui.visibleSessionClips
import org.junit.Assert.assertEquals
import org.junit.Test

class ClipOrderingTest {
    @Test
    fun recoveredClipsSwipeInGalleryOrderWithReelAndOriginalLast() {
        val clips = listOf(
            Clip(id = "original", displayName = "Original Video", filePath = "file:///original.mp4"),
            Clip(id = "one", displayName = "Clip #1", filePath = "file:///1.mp4", highlightIndex = 1),
            Clip(id = "three", displayName = "Clip #3", filePath = "file:///3.mp4", highlightIndex = 3),
            Clip(id = "reel", displayName = "Highlight Reel", filePath = "file:///reel.mp4", isReel = true),
            Clip(id = "four", displayName = "Clip #4", filePath = "file:///4.mp4", highlightIndex = 4),
            Clip(id = "two", displayName = "Clip #2", filePath = "file:///2.mp4", highlightIndex = 2),
            Clip(id = "five", displayName = "Clip #5", filePath = "file:///5.mp4", highlightIndex = 5)
        )

        assertEquals(listOf("one", "two", "three", "four", "five", "reel", "original"),
            visibleSessionClips(clips, ClipFilter.ALL).map { it.id })
        assertEquals(listOf("one", "two", "three", "four", "five"),
            visibleSessionClips(clips, ClipFilter.HIGHLIGHTS).map { it.id })
    }
}
