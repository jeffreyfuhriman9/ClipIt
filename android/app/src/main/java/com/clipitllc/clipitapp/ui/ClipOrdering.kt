package com.clipitllc.clipitapp.ui

/** The Library grid and swipe player must show the same playable clips in the same order. */
internal fun visibleSessionClips(clips: List<Clip>, filter: ClipFilter): List<Clip> = clips
    .asSequence()
    .filter { !it.isProcessing && it.filePath != null }
    .filter { clip ->
        when (filter) {
            ClipFilter.ALL -> true
            ClipFilter.HIGHLIGHTS -> clip.highlightIndex != null && !clip.isReel && !clip.isSecondaryAngle
            ClipFilter.FAVORITES -> clip.isFavorite
            ClipFilter.REELS -> clip.isReel || clip.displayName.contains("Highlight Reel")
            ClipFilter.FULL_RECORDINGS -> clip.highlightIndex == null && !clip.isReel && !clip.isSecondaryAngle
        }
    }
    .sortedWith(compareBy<Clip> { clip ->
        when {
            clip.isReel -> 1
            clip.highlightIndex == null -> 2
            else -> 0
        }
    }.thenBy { it.highlightIndex ?: Int.MAX_VALUE }
        .thenBy { it.timestamp ?: Long.MAX_VALUE }
        .thenBy { it.id })
    .toList()
