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
    simpleRemote.setSerial(nss);
    advancedRemote.setSerial(nss);
    
    advancedRemote.setFeedbackHandler(feedbackHandler);
    advancedRemote.setTimeAndStatusHandler(timeAndStatusHandler);
    advancedRemote.setPlaylistPositionHandler(playlistPositionHandler);
    advancedRemote.setTitleHandler(titleHandler);
    advancedRemote.setArtistHandler(artistHandler);
    advancedRemote.setAlbumHandler(albumHandler);
    advancedRemote.setPollingHandler(pollingHandler);
    
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
    
    // @todo set mode in the feedback handler
    mode = MODE_SWITCHING_TO_ADVANCED;
    
    advancedRemote.getTimeAndStatusInfo();
    
    updateAdvancedModeExpirationTimestamp();
}
// }}}

// {{{ IPodWrapper::updateAdvancedModeExpirationTimestamp
void IPodWrapper::updateAdvancedModeExpirationTimestamp() {
    // 500ms to switch to advanced
    advancedModeExpirationTimestamp = millis() + 500L;
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
            DEBUG_PGM_PRINTLN("iPod found");
            
            nss->flush();
            
            setSimple();
        }
    }
    else if (mode == MODE_SIMPLE) {
        if (! digitalRead(rxPin)) {
            // transition from found to not-found
            DEBUG_PGM_PRINTLN("iPod went away in simple mode");
            
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
            DEBUG_PGM_PRINTLN("iPod went away in (or never entered into) advanced mode");
            
            reset();
        }
    }
    
    if ((oldMode == MODE_SWITCHING_TO_ADVANCED) && (mode == MODE_ADVANCED)) {
        // successfully switched to advanced mode; start polling
        advancedRemote.setPollingMode(AdvancedRemote::POLLING_START);
    }
    
    if ((oldMode != mode) && (pIPodModeChangedHandler != NULL)) {
        pIPodModeChangedHandler(mode);
    }
    
    if (isPresent()) {
        syncPlayingState();

        // WAG on the update interval; when polling's working, we get track 
        // position updates every 500ms
        if (isAdvancedModeActive()) {
            if (metaUpdateInProgress && (updateMetaState == UPDATE_META_DONE)) {
                if (pMetaDataChangedHandler != NULL) {
                    pMetaDataChangedHandler();
                }
            }
            
            // @todo if (millis() > (iPodState.lastTimeAndStatusUpdate + 1000L)) {
            // @todo     DEBUG_PGM_PRINTLN("requesting time and status info");
            // @todo     advancedRemote.getTimeAndStatusInfo();
            // @todo     iPodState.lastTimeAndStatusUpdate = millis() + 250L;
            // @todo }
            // @todo     
            // @todo if (millis() > (iPodState.lastPollUpdate + 1000L)) {
            // @todo     DEBUG_PGM_PRINTLN("(re)starting polling");
            // @todo     advancedRemote.setPollingMode(AdvancedRemote::POLLING_START);
            // @todo     iPodState.lastPollUpdate = millis() + 250L;
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

// {{{ IPodWrapper::syncPlayingState
void IPodWrapper::syncPlayingState() {
    if (isPresent() && (requestedPlayingState != currentPlayingState))  {
        // we're gonna play stupid and just try the simple remote commands
        
        if (requestedPlayingState == PLAY_STATE_PLAYING) {
            simpleRemote.sendiPodOn();
            delay(50);
            simpleRemote.sendButtonReleased();

            delay(50);

            simpleRemote.sendJustPlay();
            delay(50);
            simpleRemote.sendButtonReleased();
        } else {
            // paused or stopped; just go with paused

            simpleRemote.sendJustPause();
            delay(50);
            simpleRemote.sendButtonReleased();
        }
    }
    
    currentPlayingState = requestedPlayingState;
}
// }}}

// ======= iPod handlers
// {{{ IPodWrapper::feedbackHandler
void IPodWrapper::feedbackHandler(AdvancedRemote::Feedback feedback, byte cmd) {
    // don't think this is useful, unless it will handle the mode switch,
    // which I don't think is currently happening. But any feedback is good
    // feedback, because it shows that the iPod is connected.
    
    // advancedActive = true;
    
    // @todo implement timeout so that when iPod disappears we react 
    // accordingly
    DEBUG_PGM_PRINT("got feedback for cmd ");
    DEBUG_PRINT(cmd, HEX);
    DEBUG_PGM_PRINT(", result ");
    DEBUG_PRINTLN(feedback, HEX);
}

// {{{ IPodWrapper::timeAndStatusHandler
void IPodWrapper::timeAndStatusHandler(unsigned long trackLengthInMilliseconds,
                                       unsigned long elapsedTimeInMilliseconds,
                                       AdvancedRemote::PlaybackStatus status)
{
    // this is the first method invoked after entering into
    // MODE_SWITCHING_TO_ADVANCED; confirm that advanced is now active.
    if (mode == MODE_SWITCHING_TO_ADVANCED) {
        mode = MODE_ADVANCED;
    }
    
    updateAdvancedModeExpirationTimestamp();
        
    DEBUG_PGM_PRINT("time and status updated; playback status: ");
    DEBUG_PRINTLN(status);
    
    currentTrackLengthInMilliseconds = trackLengthInMilliseconds;
    currentTrackElapsedTimeInMilliseconds = elapsedTimeInMilliseconds;

    if (status == AdvancedRemote::PLAYBACK_CONTROL_STOPPED) {
        currentPlayingState = PLAY_STATE_STOPPED;
    } else if (status == AdvancedRemote::PLAYBACK_CONTROL_PLAYING) {
        currentPlayingState = PLAY_STATE_PLAYING;
    } else if (status == AdvancedRemote::PLAYBACK_CONTROL_PAUSED) {
        currentPlayingState = PLAY_STATE_PAUSED;
    } else {
        currentPlayingState = PLAY_STATE_UNKNOWN;
    }

    if (currentPlayingState != PLAY_STATE_STOPPED) {
        advancedRemote.getPlaylistPosition();
    }
}
// }}}

// {{{ IPodWrapper::playlistPositionHandler
void IPodWrapper::playlistPositionHandler(unsigned long _playlistPosition) {
    updateAdvancedModeExpirationTimestamp();

    DEBUG_PGM_PRINTLN("servicing playlist position update");
    
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

// {{{ IPodWrapper::titleHandler
void IPodWrapper::titleHandler(const char *title) {
    free(trackName);
    
    trackName = (char *) malloc(strlen(title));
    
    if (trackName != NULL) {
        strcpy(trackName, title);
    }

    DEBUG_PGM_PRINT("got track title: ");
    DEBUG_PRINTLN(trackName);
    
    updateMetaState = UPDATE_META_ARTIST;
    advancedRemote.getArtist(playlistPosition);
}
// }}}

// {{{ IPodWrapper::artistHandler
void IPodWrapper::artistHandler(const char *artist) {
    free(artistName);
    
    artistName = (char *) malloc(strlen(artist));
    
    if (artistName != NULL) {
        strcpy(artistName, artist);
    }

    DEBUG_PGM_PRINT("got artist title: ");
    DEBUG_PRINTLN(artistName);

    updateMetaState = UPDATE_META_ALBUM;
    advancedRemote.getAlbum(playlistPosition);
}
// }}}

// {{{ IPodWrapper::albumHandler
void IPodWrapper::albumHandler(const char *album) {
    free(albumName);
    
    albumName = (char *) malloc(strlen(album));
    
    if (albumName != NULL) {
        strcpy(albumName, album);
    }

    DEBUG_PGM_PRINT("got album title: ");
    DEBUG_PRINTLN(albumName);
    
    updateMetaState = UPDATE_META_DONE;
}
// }}}

// {{{ IPodWrapper::pollingHandler
void IPodWrapper::pollingHandler(AdvancedRemote::PollingCommand command,
                                 unsigned long playlistPositionOrelapsedTimeMs)
{
    updateAdvancedModeExpirationTimestamp();

    if (command == AdvancedRemote::POLLING_TRACK_CHANGE) {
        DEBUG_PGM_PRINT("track change to: ");
        DEBUG_PRINTLN(playlistPositionOrelapsedTimeMs, DEC);

        playlistPositionHandler(playlistPositionOrelapsedTimeMs);
    }
    else if (command == AdvancedRemote::POLLING_ELAPSED_TIME) {
        // unsigned long totalSecs = playlistPositionOrelapsedTimeMs / 1000;
        // unsigned int mins = totalSecs / 60;
        // unsigned int partialSecs = totalSecs % 60;
        // 
        // DEBUG_PGM_PRINT("elapsed time: ");
        // DEBUG_PRINT(mins, DEC);
        // DEBUG_PGM_PRINT("m ");
        // DEBUG_PRINT(partialSecs, DEC);
        // DEBUG_PGM_PRINTLN("s");
    }
    else {
        DEBUG_PGM_PRINT("unknown polling command: ");
        DEBUG_PRINTLN(playlistPositionOrelapsedTimeMs, DEC);
    }
}
// }}}

