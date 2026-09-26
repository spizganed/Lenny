package com.spizganed.android_camera

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** JVM-only checks of the camera math that doesn't need a camera (the rest needs a real phone). */
class PipelineMathTest {
    private val panCrop = Pipeline.Companion::panCrop

    @Test fun centredZoomIsPurePlatformZoom() {
        val (ratio, crop) = panCrop(4000, 3000, 2f, 0.5f, 0.5f, true)
        assertEquals(2f, ratio!!, 0f)
        assertNull(crop) // the platform picks the sensor; no crop region
    }

    @Test fun noZoomNothingToPan() {
        assertEquals(1f to null, panCrop(4000, 3000, 1f, 0f, 1f, true).let { it.first to it.second })
        assertNull(panCrop(4000, 3000, 0.6f, 0f, 0f, false).second)
    }

    @Test fun panToTheLeftEdgeWithZoomRatio() {
        // 2x, window against the left edge: [0, 1000..] of 4000x3000. The zoomed view must contain it, so the ratio
        // drops to 1 and the crop is the window itself, in (now identical) post-zoom coordinates.
        val (ratio, crop) = panCrop(4000, 3000, 2f, 0f, 0.5f, true)
        assertEquals(1f, ratio!!, 1e-4f)
        assertArrayEquals(intArrayOf(0, 750, 2000, 2250), crop)
    }

    @Test fun partialPanKeepsSomeRatio() {
        // 4x, a bit right of centre: window 1000x750 centred at x=2375. zr = 4000 / (2*375 + 1000) = 2.2857.
        val (ratio, crop) = panCrop(4000, 3000, 4f, 0.625f, 0.5f, true)
        assertEquals(4000f / 1750f, ratio!!, 1e-3f)
        // In post-zoom coordinates the window fills 1/1.75 of the width, pushed to the right edge.
        assertEquals(4000, crop!![2])
        assertEquals((4000 - 4000 / 1.75f).toDouble(), crop[0].toDouble(), 2.0)
    }

    @Test fun beforeApi30TheCropDoesEverything() {
        val (ratio, crop) = panCrop(4000, 3000, 2f, 1f, 0f, false)
        assertNull(ratio)
        assertArrayEquals(intArrayOf(2000, 0, 4000, 1500), crop)
    }

    @Test fun nearestModeKeepsAspectThenAreaThenFps() {
        val modes = intArrayOf(1920, 1080, 30, 1, 1920, 1080, 60, 1, 1280, 720, 30, 1, 1440, 1080, 30, 1)
        assertArrayEquals(intArrayOf(1920, 1080, 60, 1), Pipeline.nearestMode(modes, 1920, 1080, 60))
        assertArrayEquals(intArrayOf(1920, 1080, 30, 1), Pipeline.nearestMode(modes, 3840, 2160, 30)) // no 4K here
        assertArrayEquals(intArrayOf(1440, 1080, 30, 1), Pipeline.nearestMode(modes, 1280, 960, 24)) // 4:3 stays 4:3
    }

    @Test fun aspectKeyGroups() {
        assertEquals(16 to 9, Pipeline.aspectKey(1280, 720))
        assertEquals(4 to 3, Pipeline.aspectKey(4000, 3000))
    }
}
