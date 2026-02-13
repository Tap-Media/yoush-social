import PropTypes from 'prop-types';
import { PureComponent } from 'react';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { Helmet } from 'react-helmet';
import { connect } from 'react-redux';
import HistoryIcon from '@/material-icons/400-24px/history.svg?react';
import { SymbolLogo } from 'mastodon/components/logo';
import { expandMemories } from 'mastodon/actions/memories';
import { addColumn, removeColumn, moveColumn } from 'mastodon/actions/columns';
import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';
import StatusListContainer from 'mastodon/features/ui/containers/status_list_container';
import { withBreakpoint } from 'mastodon/features/ui/hooks/useBreakpoint';

const messages = defineMessages({
  title: { id: 'column.memories', defaultMessage: 'Memories' },
});

const mapStateToProps = state => ({
  hasUnread: state.getIn(['timelines', 'memories', 'unread']) > 0,
});

class Memories extends PureComponent {
  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    matchesBreakpoint: PropTypes.bool,
    hasUnread: PropTypes.bool,
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;
    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('MEMORIES', {}));
    }
  };

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  };

  handleHeaderClick = () => {
    this.column.scrollTop();
  };

  setRef = c => {
    this.column = c;
  };

  handleLoadMore = maxId => {
    this.props.dispatch(expandMemories({ maxId }));
  };

  componentDidMount () {
    this.props.dispatch(expandMemories());
  }

  render () {
    const { intl, columnId, multiColumn, matchesBreakpoint, hasUnread } = this.props;
    const pinned = !!columnId;

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)}>
        <ColumnHeader
          icon='history'
          iconComponent={matchesBreakpoint ? SymbolLogo : HistoryIcon}
          active={hasUnread}
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
        >
        </ColumnHeader>

        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`memories_timeline-${columnId}`}
          onLoadMore={this.handleLoadMore}
          timelineId='memories'
          emptyMessage={<FormattedMessage id='empty_column.memories' defaultMessage='No memories found for today.' />}
          bindToDocument={!multiColumn}
        />

        <Helmet>
          <title>{intl.formatMessage(messages.title)}</title>
          <meta name='robots' content='noindex' />
        </Helmet>
      </Column>
    );
  }
}

export default connect(mapStateToProps)(withBreakpoint(injectIntl(Memories)));
