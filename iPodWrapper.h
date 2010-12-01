#ifndef IPODWRAPPER_H
#define IPODWRAPPER_H

#include <NewSoftSerial.h>

#include <iPodSerial.h>
#include <AdvancedRemote.h>
#include <SimpleRemote.h>

class IPodWrapper {
private:
    enum IPodMode {
        MODE_UNKNOWN,
        MODE_SIMPLE,
        MODE_SWITCHING_TO_ADVANCED,
        MODE_ADVANCED
    };
    
    enum IPodMode mode;
    
    enum UpdateMetaState {
        UPDATE_META_TITLE,
        UPDATE_META_ARTIST,
        UPDATE_META_ALBUM,
        UPDATE_META_DONE
    };
    
    enum UpdateMetaState updateMetaState;
    
    enum IPodPlayingState {
        PLAY_STATE_UNKNOWN,
        PLAY_STATE_PLAYING,
        PLAY_STATE_PAUSED,
        PLAY_STATE_STOPPED
    };
    
    enum IPodPlayingState currentPlayingState;
    enum IPodPlayingState requestedPlayingState;
    
    // per-object data
    uint8_t rxPin;
    NewSoftSerial *nss;
    
    iPodSerial *activeRemote;
    SimpleRemote simpleRemote;
    AdvancedRemote advancedRemote;
    
    unsigned long playlistPosition;

    char *trackName;
    char *artistName;
    char *albumName;

    unsigned long lastTimeAndStatusUpdate;
    unsigned long lastPollUpdate;
    
    // event flag; set to true when a track change is detected
    boolean trackChanged;
    
    // callback handlers
    void feedbackHandler(AdvancedRemote::Feedback feedback, byte cmd);
    void iPodNameHandler(const char *ipodName);
    void timeAndStatusHandler(unsigned long trackLengthInMilliseconds,
                              unsigned long elapsedTimeInMilliseconds,
                              AdvancedRemote::PlaybackStatus status);
    void playlistPositionHandler(unsigned long playlistPosition);
    void titleHandler(const char *title);
    void artistHandler(const char *artist);
    void albumHandler(const char *album);
    void pollingHandler(AdvancedRemote::PollingCommand command,
                        unsigned long playlistPositionOrelapsedTimeMs);
    
    void reset();
    void syncPlayingState();
    
    TrackChangedHandler_t *pTrackChangedHandler;
    MetaDataChangedHandler_t *pMetaDataChangedHandler;
    IPodModeChangedHandler_t *pIPodModeChangedHandler;
    
public:
    // handler definitions
    typedef void TrackChangedHandler_t(unsigned long playlistPosition);
    typedef void MetaDataChangedHandler_t();
    typedef void IPodModeChangedHandler_t(enum IPodMode mode);

    // CONFIGURATION ========================================================
    
    void setTrackChangedHandler(TrackChangedHandler_t newHandler);
    void setMetaDataChangedHandler(MetaDataChangedHandler_t newHandler);
    void setModeChangedHandler(IPodModeChangedHandler_t newHandler);
    
    /*
     * Call after handlers are configured.
     */
    init(NewSoftSerial *_nss, uint8_t _rxPin);
    
    // GETTERS ==============================================================
    /*
     * Returns true if the iPod is present.
     */
    boolean isPresent();
     
    /*
     * Returns true if Advanced mode is active.
     */
    boolean isAdvancedModeActive();

    char *getTitle();
    char *getArtist();
    char *getAlbum();
    unsigned long getPlaylistPosition();
    
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
    
    void nextTrack();
    void prevTrack();
    void nextAlbum();
    void prevAlbum();
    
    void play();
    void pause();
};

#endif