#define DEBUG 1
#include "iPodWrapper.h"

/**
    mode switches:
    MODE_UNKNOWN (initial)
        detect high on RX pin -> MODE_SIMPLE
    MODE_SIMPLE
        advancedModeRequested -> MODE_SWITCHING_TO_ADVANCED
        detect low on RX pin -> MODE_UNKNOWN
    MODE_SWITCHING_TO_ADVANCED
        handleTimeAndStatus() -> MODE_ADVANCED
        timeout -> MODE_UNKNOWN
    MODE_ADVANCED
        timeout -> MODE_UNKNOWN
 **/

#include "pgm_util.h"

#if DEBUG
    extern Print *console;
#endif

// {{{ IPodWrapper constructor
IPodWrapper::IPodWrapper() {
    // these are set directly
    pTrackChangedHandler = NULL;
    pMetaDataChangedHandler = NULL;
    pIPodModeChangedHandler = NULL;
    pIPodPlayingStateChangedHandler = NULL;
    
    requestedPlayingState = PLAY_STATE_PAUSED;
}
// }}}

// {{{ IPodWrapper::setTrackChangedHandler
void IPodWrapper::setTrackChangedHandler(TrackChangedHandler_t newHandler) {
    pTrackChangedHandler = newHandler;
}
// }}}

// {{{ IPodWrapper::setMetaDataChangedHandler
void IPodWrapper::setMetaDataChangedHandler(MetaDataChangedHandler_t newHandler) {
    pMetaDataChangedHandler = newHandler;
}
// }}}

// {{{ IPodWrapper::setModeChangedHandler
void IPodWrapper::setModeChangedHandler(IPodModeChangedHandler_t newHandler) {
    pIPodModeChangedHandler = newHandler;
}
// }}}

// {{{ IPodWrapper::setPlayStateChangedHandler
void IPodWrapper::setPlayStateChangedHandler(IPodPlayingStateChangedHandler_t newHandler) {
    pIPodPlayingStateChangedHandler = newHandler;
}
// }}}

// {{{ IPodWrapper::init
void IPodWrapper::init(Stream *_stream, uint8_t _rxPin) {
    rxPin = _rxPin;
    stream = _stream;
    lastUpdateInvocation = millis();
    
    simpleRemote.setSerial(*stream);
    advancedRemote.setSerial(*stream);
    
    // #if DEBUG
    //     simpleRemote.setLogPrint(*console);
    //     simpleRemote.setDebugPrint(*console);
    //     advancedRemote.setLogPrint(*console);
    //     advancedRemote.setDebugPrint(*console);
    // #endif
    
    // enable remote callbacks
    advancedRemote.setListener(this);
    
    reset();
}
// }}}

// {{{ IPodWrapper::reset
/*
 * Resets our interpretation of the iPod's state and configures us to use the
 * simple remote.
 */
void IPodWrapper::reset() {
    DEBUG_PGM_PRINTLN("[wrap] resetting; MODE_UNKNOWN");
    
    mode = MODE_UNKNOWN;
    updateMetaState = UPDATE_META_DONE;
    
    currentPlayingState = PLAY_STATE_UNKNOWN;
    
    playlistPosition = 0;
    
    free(trackName);
    trackName = NULL;
    
    free(artistName);
    artistName = NULL;
    
    free(albumName);
    albumName = NULL;
    
    willExpire = false;
}
// }}}

// {{{ IPodWrapper::isPresent
bool IPodWrapper::isPresent() {
    return (mode != MODE_UNKNOWN);
}
// }}}

// {{{ IPodWrapper::isAdvancedModeActive
bool IPodWrapper::isAdvancedModeActive() {
    return (mode == MODE_ADVANCED);
}
// }}}

// {{{ IPodWrapper::getTitle
char *IPodWrapper::getTitle() {
    return trackName;
}
// }}}

// {{{ IPodWrapper::getArtist
char *IPodWrapper::getArtist() {
    return artistName;
}
// }}}

// {{{ IPodWrapper::getAlbum
char *IPodWrapper::getAlbum() {
    return albumName;
}
// }}}

// {{{ IPodWrapper::getPlaylistPosition
unsigned long IPodWrapper::getPlaylistPosition() {
    return playlistPosition;
}
// }}}

// {{{ IPodWrapper::getPlayingState
IPodWrapper::IPodPlayingState IPodWrapper::getPlayingState() {
    return currentPlayingState;
}
// }}}

// {{{ IPodWrapper::switchToSimple
void IPodWrapper::switchToSimple() {
    DEBUG_PGM_PRINTLN("[wrap] setting MODE_SIMPLE");
    mode = MODE_SIMPLE;
    
    // the Dension ice>Link: Plus does this; might be a wakeup of some kind?
    stream->write('\xff');
    delay(21);
    
    advancedRemote.disable();
    activeRemote = &simpleRemote;
}
// }}}

// {{{ IPodWrapper::switchToAdvanced
void IPodWrapper::switchToAdvanced() {
    activeRemote = &advancedRemote;
    advancedRemote.enable();
    
    DEBUG_PGM_PRINTLN("[wrap] setting MODE_SWITCHING_TO_ADVANCED");
    mode = MODE_SWITCHING_TO_ADVANCED;
    
    advancedRemote.getTimeAndStatusInfo();
    
    updateAdvancedModeExpirationTimestamp();
}
// }}}

// {{{ IPodWrapper::initiateMetadataUpdate
void IPodWrapper::initiateMetadataUpdate() {
    // free malloc'd memory for meta data; doing it here should help
    // avoid heap fragmentation…
    free(trackName);
    trackName = NULL;

    free(artistName);
    artistName = NULL;

    free(albumName);
    albumName = NULL;

    updateMetaState = UPDATE_META_TITLE;
    advancedRemote.getTitle(playlistPosition);
    
    // allow 2s to finish updating all metadata
    metaUpdateExpirationTimestamp = millis() + 2000L;
}
// }}}

// {{{ IPodWrapper::setSimple
void IPodWrapper::setSimple() {
    advancedModeRequested = false;
}
// }}}

// {{{ IPodWrapper::setAdvanced
void IPodWrapper::setAdvanced() {
    advancedModeRequested = true;
}
// }}}

// {{{ IPodWrapper::updateAdvancedModeExpirationTimestamp
void IPodWrapper::updateAdvancedModeExpirationTimestamp() {
    // allow enough time to handle call/response when paused/stopped
    advancedModeExpirationTimestamp = millis() + 2000L;
}
// }}}

// {{{ IPodWrapper::update
void IPodWrapper::update() {
    int rx_pin_state;
    
    // attempt to test if an iPod's attached.  If the input's floating, this 
    // could be a problem.
    // @todo what about a *very* weak pull-down, which should be overridden by
    // the iPod's (presumed) pull-up?
    
    unsigned long now = millis();
    
    // throttle update calls to 250ms
    if (now < (lastUpdateInvocation + 250L)) {
        return;
    }
    
    lastUpdateInvocation = now;
    
    // advanced mode should only be enabled after we've ascertained the 
    // presence of the iPod
    IPodMode oldMode = mode;
    IPodPlayingState oldPlayState = currentPlayingState;
    
    bool metaUpdateInProgress = (updateMetaState != UPDATE_META_DONE);
    
    // process incoming data from iPod; will be a no-op for simple remote
    // iPodSerial::loop() only reads one byte at a time
    while (stream->available() > 0) {
        activeRemote->loop();
    }

    if (mode == MODE_UNKNOWN) {
        rx_pin_state = digitalRead(rxPin);
        
        if (rx_pin_state == HIGH) {
            // transition from not-found to found
            DEBUG_PGM_PRINTLN("[wrap] iPod found");
            
            stream->flush();
            
            switchToSimple();
        }
    }
    else if (mode == MODE_SIMPLE) {
        rx_pin_state = digitalRead(rxPin);
        
        if (rx_pin_state == LOW) {
            // transition from found to not-found
            DEBUG_PGM_PRINTLN("[wrap] iPod went away in simple mode");
            
            reset();
        }
    }
    else if ((mode == MODE_ADVANCED) || (mode == MODE_SWITCHING_TO_ADVANCED)) {
        // MODE_SWITCHING_TO_ADVANCED is the first mode switched to when
        // switchToAdvanced() is called. switchToAdvanced() calls 
        // getTimeAndStatusInfo(), then handleTimeAndStatus() calls
        // getPlaylistPosition() if the iPod's not stopped. Once 
        // handleTimeAndStatus() is invoked, MODE_ADVANCED is selected.
        
        // depends on a "timer" that gets reset by incoming messages in 
        // advanced mode
        
        // DEBUG_PGM_PRINT("[wrap] time to expiration: ");
        // DEBUG_PRINTLN(advancedModeExpirationTimestamp - now, DEC);
        
        if (now > advancedModeExpirationTimestamp) {
            if (! willExpire) {
                willExpire = true;
                DEBUG_PGM_PRINTLN("[wrap] timestamp update missed; will expire on next update");
            } else {
                // transition from found to not-found
                DEBUG_PGM_PRINTLN("[wrap] iPod went away in (or never entered into) advanced mode");
            
                reset();
            }
        } else {
            willExpire = false;
        }
    }
    
    // notify on changed mode, but not for MODE_SWITCHING_TO_ADVANCED
    if (
        (oldMode != mode)  && 
        (mode != MODE_SWITCHING_TO_ADVANCED) &&
        (pIPodModeChangedHandler != NULL)
    ) {
        pIPodModeChangedHandler(mode);
    }
    
    if ((oldMode == MODE_SWITCHING_TO_ADVANCED) && (mode == MODE_ADVANCED)) {
        // successfully switched to advanced mode; start polling
        advancedRemote.setPollingMode(AdvancedRemote::POLLING_START);
        
        // @todo if we need a little more time for the iPod to process the 
        // switch, update the timestamp here, too.
        // updateAdvancedModeExpirationTimestamp();
    }
    else if ((mode == MODE_SIMPLE) && advancedModeRequested) {
        switchToAdvanced();
    }
    else if (
        ((mode == MODE_SWITCHING_TO_ADVANCED) || (mode == MODE_ADVANCED)) &&
        (! advancedModeRequested)
    ) {
        switchToSimple(); 
    }
    
    if (isPresent()) {
        syncPlayingState();

        if (isAdvancedModeActive()) {
            // DEBUG_PGM_PRINTLN("[wrap] advanced mode is active");
            
            if (metaUpdateInProgress) {
                if (updateMetaState == UPDATE_META_DONE) {
                    DEBUG_PGM_PRINTLN("[wrap] metadata update complete");
                    if (pMetaDataChangedHandler != NULL) {
                        pMetaDataChangedHandler();
                    }
                } else if (millis() > metaUpdateExpirationTimestamp) {
                    DEBUG_PGM_PRINTLN("[wrap] metadata update timeout");
                    initiateMetadataUpdate();
                }
            }
            
            // this expiration timestamp is more difficult to figure out than
            // I figured it would be. When polling's enabled, we get an 
            // update every 500ms, but ONLY WHEN PLAYING.  So when we're not playing
            // we need to request info from the iPod periodically to make 
            // sure it's still alive.  It can take quite a while to get back 
            // to this update loop, so invoke the keep-alive when not playing
            // with enough time to catch the response before timing out.
            if (
                ((advancedModeExpirationTimestamp - now) < 750L) &&
                (currentPlayingState != PLAY_STATE_PLAYING))
            {
                // expiration imminent
                DEBUG_PGM_PRINTLN("[wrap] requesting time and status info for keep-alive");
                advancedRemote.getTimeAndStatusInfo();
            }
        }    
    } else {
        currentPlayingState = PLAY_STATE_UNKNOWN;
    }
    
    if ((oldPlayState != currentPlayingState) && (pIPodPlayingStateChangedHandler != NULL)) {
        pIPodPlayingStateChangedHandler(currentPlayingState);
    }
}
// }}}

// {{{ IPodWrapper::play
void IPodWrapper::play() {
    requestedPlayingState = PLAY_STATE_PLAYING;
}
// }}}

// {{{ IPodWrapper::pause
void IPodWrapper::pause() {
    requestedPlayingState = PLAY_STATE_PAUSED;
}
// }}}

// {{{ IPodWrapper::nextTrack
void IPodWrapper::nextTrack() {
    if (isAdvancedModeActive()) {
        advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_SKIP_FORWARD);
    } else {
        simpleRemote.sendSkipForward();
        delay(50);
        simpleRemote.sendButtonReleased();
    }
}
// }}}

// {{{ IPodWrapper::prevTrack
void IPodWrapper::prevTrack() {
    if (isAdvancedModeActive()) {
        advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_SKIP_BACKWARD);
    } else {
        simpleRemote.sendSkipBackward();
        delay(50);
        simpleRemote.sendButtonReleased();
    }
}
// }}}

// {{{ IPodWrapper::nextAlbum
void IPodWrapper::nextAlbum() {
    if (isAdvancedModeActive()) {
        // advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_SKIP_BACKWARD);
        // @todo
    } else {
        simpleRemote.sendNextAlbum();
        delay(50);
        simpleRemote.sendButtonReleased();
    }
}
// }}}

// {{{ IPodWrapper::prevAlbum
void IPodWrapper::prevAlbum() {
    if (isAdvancedModeActive()) {
        // advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_SKIP_BACKWARD);
        // @todo
    } else {
        simpleRemote.sendPreviousAlbum();
        delay(50);
        simpleRemote.sendButtonReleased();
    }
}
// }}}

// {{{ IPodWrapper::syncPlayingState
void IPodWrapper::syncPlayingState() {
    if (isPresent() && (requestedPlayingState != currentPlayingState))  {
        
        if (requestedPlayingState == PLAY_STATE_PLAYING) {
            DEBUG_PGM_PRINTLN("[wrap] playing state mismatch; setting iPod to play");
            
            if (isAdvancedModeActive()) {
                advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_PLAY_PAUSE);
            } else {
                simpleRemote.sendiPodOn();
                delay(50);
                simpleRemote.sendButtonReleased();

                delay(50);

                simpleRemote.sendJustPlay();
                delay(50);
                simpleRemote.sendButtonReleased();
            }
        } else {
            // paused or stopped; just go with paused
            DEBUG_PGM_PRINTLN("[wrap] playing state mismatch; setting iPod to paused");

            if (isAdvancedModeActive()) {
                advancedRemote.controlPlayback(AdvancedRemote::PLAYBACK_CONTROL_PLAY_PAUSE);
            } else {
                simpleRemote.sendJustPause();
                delay(50);
                simpleRemote.sendButtonReleased();
            }
        }
        
        // just because?
        updateAdvancedModeExpirationTimestamp();
    }
    
    currentPlayingState = requestedPlayingState;
}
// }}}

// ======= iPod handlers

// {{{ IPodWrapper::handleFeedback
void IPodWrapper::handleFeedback(AdvancedRemote::Feedback feedback, byte cmd) {
    DEBUG_PGM_PRINT("[wrap] got feedback for cmd ");
    DEBUG_PRINT(cmd, HEX);
    DEBUG_PGM_PRINT(", result ");
    DEBUG_PRINTLN(feedback, HEX);
    
    // occasionally I get FEEDBACK_INVALID_PARAM for
    // CMD_GET_TIME_AND_STATUS_INFO, which appears to mean that the iPod has
    // dropped back to Simple mode. Not sure what causes that…
    
    if (feedback == AdvancedRemote::FEEDBACK_SUCCESS) {
        updateAdvancedModeExpirationTimestamp();
    }
}

// {{{ IPodWrapper::handleTimeAndStatus
void IPodWrapper::handleTimeAndStatus(unsigned long trackLengthInMilliseconds,
                                      unsigned long elapsedTimeInMilliseconds,
                                      AdvancedRemote::PlaybackStatus status)
{
    // this is the first method invoked after entering into
    // MODE_SWITCHING_TO_ADVANCED; confirm that advanced is now active.
    if (mode == MODE_SWITCHING_TO_ADVANCED) {
        DEBUG_PGM_PRINTLN("[wrap] setting MODE_ADVANCED");
        mode = MODE_ADVANCED;
    }
    
    updateAdvancedModeExpirationTimestamp();
        
    DEBUG_PGM_PRINT("[wrap] time and status updated; playback status: ");
    
    // currentTrackLengthInMilliseconds = trackLengthInMilliseconds;
    // currentTrackElapsedTimeInMilliseconds = elapsedTimeInMilliseconds;

    if (status == AdvancedRemote::STATUS_STOPPED) {
        currentPlayingState = PLAY_STATE_STOPPED;
        DEBUG_PGM_PRINTLN("stopped");
    } else if (status == AdvancedRemote::STATUS_PLAYING) {
        currentPlayingState = PLAY_STATE_PLAYING;
        DEBUG_PGM_PRINTLN("playing");
    } else if (status == AdvancedRemote::STATUS_PAUSED) {
        currentPlayingState = PLAY_STATE_PAUSED;
        DEBUG_PGM_PRINTLN("paused");
    } else {
        currentPlayingState = PLAY_STATE_UNKNOWN;
        DEBUG_PGM_PRINTLN("unknown");
    }

    if (currentPlayingState != PLAY_STATE_STOPPED) {
        // DEBUG_PGM_PRINTLN("[wrap] requesting playlist position");
        advancedRemote.getPlaylistPosition();
    }
}
// }}}

// {{{ IPodWrapper::handlePlaylistPosition
void IPodWrapper::handlePlaylistPosition(unsigned long _playlistPosition) {
    updateAdvancedModeExpirationTimestamp();

    // DEBUG_PGM_PRINTLN("[wrap] servicing playlist position update");
    
    if (playlistPosition != _playlistPosition) {
        playlistPosition = _playlistPosition;
        
        if (pTrackChangedHandler != NULL) {
            pTrackChangedHandler(playlistPosition);
        }
        
        initiateMetadataUpdate();
    }
}
// }}}

// {{{ IPodWrapper::handleTitle
void IPodWrapper::handleTitle(const char *title) {
    DEBUG_PGM_PRINT("[wrap] got track title: ");
    DEBUG_PRINTLN(title);
    
    size_t titleLen = strlen(title);
    trackName = (char *) malloc(titleLen);
    
    if (trackName != NULL) {
        memset(trackName, 0, titleLen);
        strcpy(trackName, title);
    } else {
        DEBUG_PGM_PRINTLN("[wrap] unable to malloc for title");
    }

    updateMetaState = UPDATE_META_ARTIST;
    advancedRemote.getArtist(playlistPosition);
}
// }}}

// {{{ IPodWrapper::handleArtist
void IPodWrapper::handleArtist(const char *artist) {
    DEBUG_PGM_PRINT("[wrap] got artist title: ");
    DEBUG_PRINTLN(artist);

    size_t artistLen = strlen(artist);
    artistName = (char *) malloc(artistLen);
    
    if (artistName != NULL) {
        memset(artistName, 0, artistLen);
        strcpy(artistName, artist);
    } else {
        DEBUG_PGM_PRINTLN("[wrap] unable to malloc for artist");
    }

    updateMetaState = UPDATE_META_ALBUM;
    advancedRemote.getAlbum(playlistPosition);
}
// }}}

// {{{ IPodWrapper::handleAlbum
void IPodWrapper::handleAlbum(const char *album) {
    DEBUG_PGM_PRINT("[wrap] got album title: ");
    DEBUG_PRINTLN(album);
    
    size_t albumLen = strlen(album);
    albumName = (char *) malloc(albumLen);
    
    if (albumName != NULL) {
        memset(albumName, 0, albumLen);
        strcpy(albumName, album);
    } else {
        DEBUG_PGM_PRINTLN("[wrap] unable to malloc for album");
    }

    updateMetaState = UPDATE_META_DONE;
}
// }}}

// {{{ IPodWrapper::handlePolling
void IPodWrapper::handlePolling(AdvancedRemote::PollingCommand command,
                                        unsigned long playlistPositionOrelapsedTimeMs)
{
    updateAdvancedModeExpirationTimestamp();

    if (command == AdvancedRemote::POLLING_TRACK_CHANGE) {
        DEBUG_PGM_PRINT("[wrap] track change to: ");
        DEBUG_PRINTLN(playlistPositionOrelapsedTimeMs, DEC);

        handlePlaylistPosition(playlistPositionOrelapsedTimeMs);
    }
    else if (command == AdvancedRemote::POLLING_ELAPSED_TIME) {
        // unsigned long totalSecs = playlistPositionOrelapsedTimeMs / 1000;
        // unsigned int mins = totalSecs / 60;
        // unsigned int partialSecs = totalSecs % 60;
        // 
        // DEBUG_PGM_PRINT("[wrap] elapsed time: ");
        // DEBUG_PRINT(mins, DEC);
        // DEBUG_PGM_PRINT("m ");
        // DEBUG_PRINT(partialSecs, DEC);
        // DEBUG_PGM_PRINTLN("s");
    }
    else {
        DEBUG_PGM_PRINT("[wrap] unknown polling command: ");
        DEBUG_PRINTLN(playlistPositionOrelapsedTimeMs, DEC);
    }
}
// }}}

// no-ops
void IPodWrapper::handleIPodName(const char *ipodName) {}
void IPodWrapper::handleIPodType(const char *ipodName) {}
void IPodWrapper::handleItemCount(unsigned long count) {}
void IPodWrapper::handleItemName(unsigned long offet, const char *itemName) {}
void IPodWrapper::handleShuffleMode(AdvancedRemote::ShuffleMode mode) {}
void IPodWrapper::handleRepeatMode(AdvancedRemote::RepeatMode mode) {}
void IPodWrapper::handleCurrentPlaylistSongCount(unsigned long count) {}
