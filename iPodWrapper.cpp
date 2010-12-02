#define DEBUG 1
#include "iPodWrapper.h"

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

// {{{ IPodWrapper::init
void IPodWrapper::init(NewSoftSerial *_nss, uint8_t _rxPin) {
    rxPin = _rxPin;
    nss = _nss;
    
    // disable NSS's pull-up on the RX line; this can be done any time after
    // the nssIPod object is created
    digitalWrite(rxPin, LOW);
    
    // baud rate for iPodSerial
    nss->begin(9600);

    // don't call iPodSerial::setup(); only calls *Serial::begin(), which 
    // we're already taking care of
    // @todo verify still valid if iPodSerial is updated
    simpleRemote.setSerial(*nss);
    advancedRemote.setSerial(*nss);
    
    #if DEBUG
        // simpleRemote.setLogPrint(*console);
        // simpleRemote.setDebugPrint(*console);
        // advancedRemote.setLogPrint(*console);
        // advancedRemote.setDebugPrint(*console);
    #endif
    
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
    mode = MODE_UNKNOWN;
    updateMetaState = UPDATE_META_DONE;
    
    currentPlayingState = PLAY_STATE_UNKNOWN;
    requestedPlayingState = PLAY_STATE_PAUSED;
    
    playlistPosition = 0;
    
    free(trackName);
    trackName = NULL;
    
    free(artistName);
    artistName = NULL;
    
    free(albumName);
    albumName = NULL;
    
    lastTimeAndStatusUpdate = 0;
    lastPollUpdate = 0;
}
// }}}

// {{{ IPodWrapper::isPresent
boolean IPodWrapper::isPresent() {
    return (mode != MODE_UNKNOWN);
}
// }}}

// {{{ IPodWrapper::isAdvancedModeActive
boolean IPodWrapper::isAdvancedModeActive() {
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

// {{{ IPodWrapper::setSimple
void IPodWrapper::setSimple() {
    mode = MODE_SIMPLE;

    advancedRemote.disable();
    activeRemote = &simpleRemote;
}
// }}}

// {{{ IPodWrapper::setAdvanced
void IPodWrapper::setAdvanced() {
    activeRemote = &advancedRemote;
    advancedRemote.enable();
    
    mode = MODE_SWITCHING_TO_ADVANCED;
    
    advancedRemote.getTimeAndStatusInfo();
    
    updateAdvancedModeExpirationTimestamp();
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
    // attempt to test if an iPod's attached.  If the input's floating, this 
    // could be a problem.
    // @todo what about a *very* weak pull-down, which should be overridden by
    // the iPod's (presumed) pull-up?
    
    // advanced mode should only be enabled after we've ascertained the 
    // presence of the iPod
    enum IPodMode oldMode = mode;
    
    boolean metaUpdateInProgress = (updateMetaState != UPDATE_META_DONE);
    
    // process incoming data from iPod; will be a no-op for simple remote
    // iPodSerial::loop() only reads one byte at a time
    while (nss->available() > 0) {
        activeRemote->loop();
    }

    if (mode == MODE_UNKNOWN) {
        if (digitalRead(rxPin)) {
            // transition from not-found to found
            // DEBUG_PGM_PRINTLN("[wrap] iPod found");
            
            nss->flush();
            
            setSimple();
        }
    }
    else if (mode == MODE_SIMPLE) {
        if (! digitalRead(rxPin)) {
            // transition from found to not-found
            // DEBUG_PGM_PRINTLN("[wrap] iPod went away in simple mode");
            
            reset();
        }
    }
    else if ((mode == MODE_ADVANCED) || (mode == MODE_SWITCHING_TO_ADVANCED)) {
        // MODE_SWITCHING_TO_ADVANCED is the first mode switched to when
        // setAdvanced() is called. setAdvanced() calls getTimeAndStatusInfo(),
        // then timeAndStatusHandler() calls getPlaylistPosition() if the 
        // iPod's not stopped.
        // Once timeAndStatusHandler() is invoked, MODE_ADVANCED is selected.
        
        // depends on a "timer" that gets reset by incoming messages in 
        // advanced mode
        if (millis() > advancedModeExpirationTimestamp) {
            // transition from found to not-found
            DEBUG_PGM_PRINTLN("[wrap] iPod went away in (or never entered into) advanced mode");
            
            reset();
        }
    }
    
    if ((oldMode == MODE_SWITCHING_TO_ADVANCED) && (mode == MODE_ADVANCED)) {
        // successfully switched to advanced mode; start polling
        advancedRemote.setPollingMode(AdvancedRemote::POLLING_START);
        
        // @todo if we need a little more time for the iPod to process the 
        // switch, update the timestamp here, too.
        // updateAdvancedModeExpirationTimestamp();
    }
    
    if ((oldMode != mode) && (pIPodModeChangedHandler != NULL)) {
        pIPodModeChangedHandler(mode);
    }
    
    if (isPresent()) {
        syncPlayingState();

        if (isAdvancedModeActive()) {
            // DEBUG_PGM_PRINTLN("[wrap] advanced mode is active");
            
            if (metaUpdateInProgress && (updateMetaState == UPDATE_META_DONE)) {
                if (pMetaDataChangedHandler != NULL) {
                    pMetaDataChangedHandler();
                }
            }
            
            // DEBUG_PGM_PRINT("[wrap] advancedModeExpirationTimestamp: ");
            // DEBUG_PRINT(advancedModeExpirationTimestamp, DEC);
            // DEBUG_PGM_PRINT(", millis: ");
            // DEBUG_PRINTLN(millis(), DEC);
            
            // this expiration timestamp is more difficult to figure out than
            // I figured it would be. When polling's enabled, we get an 
            // update every 500ms, but ONLY WHEN PLAYING.  So when we're not playing
            // we need to request info from the iPod periodically to make 
            // sure it's still alive.  It can take quite a while to get back 
            // to this update loop, so invoke the keep-alive when not playing
            // with enough time to catch the response before timing out.
            if (
                ((advancedModeExpirationTimestamp - millis()) < 750L) &&
                (currentPlayingState != PLAY_STATE_PLAYING))
            {
                DEBUG_PGM_PRINTLN("[wrap] requesting time and status info for keep-alive");
                advancedRemote.getTimeAndStatusInfo();
            }
            
            // @todo if (millis() > (iPodState.lastPollUpdate + 1000L)) {
            // @todo     DEBUG_PGM_PRINTLN("(re)starting polling");
            // @todo     advancedRemote.setPollingMode(AdvancedRemote::POLLING_START);
            // @todo }
        }    
    } else {
        currentPlayingState = PLAY_STATE_UNKNOWN;
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
    // don't think this is useful, unless it will handle the mode switch,
    // which I don't think is currently happening. But any feedback is good
    // feedback, because it shows that the iPod is connected.

    DEBUG_PGM_PRINT("[wrap] got feedback for cmd ");
    DEBUG_PRINT(cmd, HEX);
    DEBUG_PGM_PRINT(", result ");
    DEBUG_PRINTLN(feedback, HEX);
    
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
        
        free(trackName);
        trackName = NULL;

        free(artistName);
        artistName = NULL;

        free(albumName);
        albumName = NULL;

        if (pTrackChangedHandler != NULL) {
            pTrackChangedHandler(playlistPosition);
        }
        
        updateMetaState = UPDATE_META_TITLE;
        advancedRemote.getTitle(playlistPosition);
    }
}
// }}}

// {{{ IPodWrapper::handleTitle
void IPodWrapper::handleTitle(const char *title) {
    free(trackName);
    
    trackName = (char *) malloc(strlen(title));
    
    if (trackName != NULL) {
        strcpy(trackName, title);
    }

    DEBUG_PGM_PRINT("[wrap] got track title: ");
    DEBUG_PRINTLN(trackName);
    
    updateMetaState = UPDATE_META_ARTIST;
    advancedRemote.getArtist(playlistPosition);
}
// }}}

// {{{ IPodWrapper::handleArtist
void IPodWrapper::handleArtist(const char *artist) {
    free(artistName);
    
    artistName = (char *) malloc(strlen(artist));
    
    if (artistName != NULL) {
        strcpy(artistName, artist);
    }

    DEBUG_PGM_PRINT("[wrap] got artist title: ");
    DEBUG_PRINTLN(artistName);

    updateMetaState = UPDATE_META_ALBUM;
    advancedRemote.getAlbum(playlistPosition);
}
// }}}

// {{{ IPodWrapper::handleAlbum
void IPodWrapper::handleAlbum(const char *album) {
    free(albumName);
    
    albumName = (char *) malloc(strlen(album));
    
    if (albumName != NULL) {
        strcpy(albumName, album);
    }

    DEBUG_PGM_PRINT("[wrap] got album title: ");
    DEBUG_PRINTLN(albumName);
    
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
        unsigned long totalSecs = playlistPositionOrelapsedTimeMs / 1000;
        unsigned int mins = totalSecs / 60;
        unsigned int partialSecs = totalSecs % 60;
        
        DEBUG_PGM_PRINT("elapsed time: ");
        DEBUG_PRINT(mins, DEC);
        DEBUG_PGM_PRINT("m ");
        DEBUG_PRINT(partialSecs, DEC);
        DEBUG_PGM_PRINTLN("s");
    }
    else {
        DEBUG_PGM_PRINT("[wrap] unknown polling command: ");
        DEBUG_PRINTLN(playlistPositionOrelapsedTimeMs, DEC);
    }
}
// }}}

// no-ops
void IPodWrapper::handleIPodName(const char *ipodName) {}
void IPodWrapper::handleItemCount(unsigned long count) {}
void IPodWrapper::handleItemName(unsigned long offet, const char *itemName) {}
void IPodWrapper::handleShuffleMode(AdvancedRemote::ShuffleMode mode) {}
void IPodWrapper::handleRepeatMode(AdvancedRemote::RepeatMode mode) {}
void IPodWrapper::handleCurrentPlaylistSongCount(unsigned long count) {}
