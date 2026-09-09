import { Component, createRef } from "react";
import { ScrollView, type ScrollViewProps } from "react-native";

type Props = Pick<ScrollViewProps, "children" | "style" | "contentContainerStyle"> & {
  orderKey: string;
  query: string;
};
type Anchor = { id: string; offset: number };

/** Capture before DOM mutations so a background regroup keeps the reading position. */
export class SessionViewport extends Component<Props> {
  private scroller = createRef<ScrollView>();

  getSnapshotBeforeUpdate(previous: Props): Anchor[] | null {
    if (previous.query !== this.props.query || previous.orderKey === this.props.orderKey) return null;
    const node = this.scroller.current?.getScrollableNode() as HTMLElement | undefined;
    if (!node) return null;
    const top = node.getBoundingClientRect().top;
    const rows = Array.from(node.querySelectorAll<HTMLElement>('[id^="session-row-"]'));
    const first = rows.findIndex(row => row.getBoundingClientRect().bottom > top);
    if (first < 0) return null;
    // Prefer the top row, then its following neighbors, then preceding rows
    // if a catalog update removes the remaining tail of the list.
    return [...rows.slice(first), ...rows.slice(0, first).reverse()]
      .map(row => ({ id: row.id, offset: row.getBoundingClientRect().top - top }));
  }

  componentDidUpdate(_previous: Props, _state: unknown, anchors: Anchor[] | null) {
    const node = this.scroller.current?.getScrollableNode() as HTMLElement | undefined;
    if (!node || !anchors) return;
    for (const anchor of anchors) {
      const row = document.getElementById(anchor.id);
      if (!row || !node.contains(row)) continue;
      node.scrollTop += row.getBoundingClientRect().top - node.getBoundingClientRect().top - anchor.offset;
      break;
    }
  }

  render() {
    return <ScrollView ref={this.scroller} style={this.props.style} contentContainerStyle={this.props.contentContainerStyle}>
      {this.props.children}
    </ScrollView>;
  }
}
