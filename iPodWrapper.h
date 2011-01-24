#ifndef IPODWRAPPER_H
#define IPODWRAPPER_H

#include "Stream.h"

// #include <iPodSerial.h>
#include <AdvancedRemote.h>
#include <SimpleRemote.h>

class IPodWrapper : public AdvancedRemote::AdvancedRemoteListener {
public:
    enum IPodMode {
        MODE_UNKNOWN,
        MODE_SIMPLE,
        MODE_SWITCHING_TO_ADVANCED,
        MODE_ADVANCED
    };
    
    enum UpdateMetaState {
        UPDATE_META_TITLE,
        UPDATE_META_ARTIST,
        UPDATE_META_ALBUM,
        UPDATE_META_DONE
    };
    
    enum IPodPlayingState {
        PLAY_STATE_UNKNOWN,
        PLAY_STATE_PLAYING,
        PLAY_STATE_PAUSED,
        PLAY_STATE_STOPPED
    };
    
    // handler definitions
    typedef void TrackChangedHandler_t(unsigned long playlistPosition);
    typedef void MetaDataChangedHandler_t();
    typedef void IPodModeChangedHandler_t(IPodMode mode);
    typedef void IPodPlayingStateChangedHandler_t(IPodPlayingState playingState);

private:
    uint8_t rxPin;
    Stream *stream;
    
    iPodSerial *activeRemote;
    SimpleRemote simpleRemote;
    AdvancedRemote advancedRemote;
    
    IPodMode mode;
    bool advancedModeRequested;
    
    UpdateMetaState updateMetaState;
    IPodPlayingState currentPlayingState;
    IPodPlayingState requestedPlayingState;
    
    unsigned long playlistPosition;

    // used to throttle calls to update()
    unsigned long lastUpdateInvocation;
    
    unsigned long advancedModeExpirationTimestamp;
    bool willExpire;

    unsigned long metaUpdateExpirationTimestamp;

    char *trackName;
    char *artistName;
    char *albumName;
    
    // event flag; set to true when a track change is detected
    bool trackChanged;
    
    TrackChangedHandler_t *pTrackChangedHandler;
    MetaDataChangedHandler_t *pMetaDataChangedHandler;
    IPodModeChangedHandler_t *pIPodModeChangedHandler;
    IPodPlayingStateChangedHandler_t *pIPodPlayingStateChangedHandler;

    void reset();
    void syncPlayingState();
    void updateAdvancedModeExpirationTimestamp();
    
    void switchToSimple();
    void switchToAdvanced();
    
    void initiateMetadataUpdate();
    
public:
    // CONSTRUCTOR ==========================================================
    IPodWrapper();
    
    // CONFIGURATION ========================================================
    
    void setTrackChangedHandler(TrackChangedHandler_t newHandler);
    void setMetaDataChangedHandler(MetaDataChangedHandler_t newHandler);
    void setModeChangedHandler(IPodModeChangedHandler_t newHandler);
    void setPlayStateChangedHandler(IPodPlayingStateChangedHandler_t newHandler);
    
    /*
     * Call after handlers are configured.
     */
    void init(Stream *_stream, uint8_t _rxPin);
    
    // GETTERS ==============================================================
    /*
     * Returns true if the iPod is present.
     */
    bool isPresent();
     
    /*
     * Returns true if Advanced mode is active.
     */
    bool isAdvancedModeActive();

    char *getTitle();
    char *getArtist();
    char *getAlbum();
    unsigned long getPlaylistPosition();
    IPodPlayingState getPlayingState();
    
    // CONTROL ==============================================================
    /*
     * Attempts to switch to Advanced mode.
     */
    void setAdvanced();

    /*
     * Switches to Simple mode.
     */
    void setSimple();
    
    /*
     * Call periodically to respond to iPod and update state.
     */
    void update();
    
    void play();
    void pause();

    void nextTrack();
    void prevTrack();
    void nextAlbum();
    void prevAlbum();
    
    // CALLBACK HANDLERS ====================================================
    virtual void handleFeedback(AdvancedRemote::Feedback feedback, byte cmd);
    virtual void handleIPodName(const char *ipodName);
    virtual void handleIPodType(const char *ipodType);
    virtual void handleItemCount(unsigned long count);
    virtual void handleItemName(unsigned long offet, const char *itemName);
    virtual void handleTimeAndStatus(unsigned long trackLengthInMilliseconds,
                                     unsigned long elapsedTimeInMilliseconds,
                                     AdvancedRemote::PlaybackStatus status);
    virtual void handlePlaylistPosition(unsigned long playlistPosition);
    virtual void handleTitle(const char *title);
    virtual void handleArtist(const char *artist);
    virtual void handleAlbum(const char *album);
    virtual void handlePolling(AdvancedRemote::PollingCommand command,
                               unsigned long playlistPositionOrelapsedTimeMs);
    virtual void handleShuffleMode(AdvancedRemote::ShuffleMode mode);
    virtual void handleRepeatMode(AdvancedRemote::RepeatMode mode);
    virtual void handleCurrentPlaylistSongCount(unsigned long count);
};

#endif
